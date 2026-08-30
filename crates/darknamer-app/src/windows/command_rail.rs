use std::cell::Cell;
use std::ffi::c_void;
use std::io;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::HWND;
#[cfg(test)]
use windows_sys::Win32::Foundation::RECT;
#[cfg(test)]
use windows_sys::Win32::Graphics::Gdi::MapWindowPoints;
use windows_sys::Win32::Graphics::Gdi::{
    CreateSolidBrush, DeleteObject, HBRUSH, HFONT, InvalidateRect,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemServices::SS_ETCHEDHORZ;
use windows_sys::Win32::UI::Controls::{
    TOOLTIPS_CLASSW, TTF_IDISHWND, TTF_SUBCLASS, TTM_ADDTOOLW, TTS_ALWAYSTIP, TTTOOLINFOW,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::GetWindowRect;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BS_CENTER, BS_MULTILINE, BS_NOTIFY, BS_PUSHBUTTON, BS_VCENTER, CreateWindowExW, DestroyWindow,
    GWL_STYLE, GetWindowLongPtrW, SW_HIDE, SW_SHOW, SendMessageW, SetWindowLongPtrW, ShowWindow,
    WM_SETFONT, WS_CHILD, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP, WS_TABSTOP, WS_VISIBLE,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::{
    SWP_NOACTIVATE, SWP_NOREDRAW, SWP_NOZORDER, SetWindowPos,
};

use super::{
    APPLY, APPLY_KEYLINE_COLOR, CommandId, CommandPlacement, CommandRailSpec, LayoutRect,
    calculate_apply_keyline_layout, calculate_command_rail_separator_layout, command_ui_spec, wide,
};

#[derive(Debug)]
struct CommandButton {
    command: CommandId,
    window: HWND,
}

#[derive(Debug)]
struct OwnedTooltip(HWND);

impl OwnedTooltip {
    fn as_raw(&self) -> HWND {
        self.0
    }

    fn destroy(&mut self) {
        if !self.0.is_null() {
            // SAFETY: this wrapper owns the tooltip HWND and destroys it once
            // before the tool text buffers referenced by that window are freed.
            unsafe { DestroyWindow(self.0) };
            self.0 = null_mut();
        }
    }
}

impl Drop for OwnedTooltip {
    fn drop(&mut self) {
        self.destroy();
    }
}

#[derive(Debug)]
struct OwnedApplyKeyline {
    window: HWND,
    brush: HBRUSH,
}

impl Drop for OwnedApplyKeyline {
    fn drop(&mut self) {
        if !self.window.is_null() {
            // SAFETY: this object solely owns the decorative child HWND. Hide
            // it before synchronous destruction so no new paint can request
            // the brush while teardown proceeds.
            unsafe {
                ShowWindow(self.window, SW_HIDE);
                DestroyWindow(self.window);
            }
            self.window = null_mut();
        }
        if !self.brush.is_null() {
            // SAFETY: the STATIC is gone, so no paint can retain this object's
            // solely owned solid brush after deletion.
            unsafe { DeleteObject(self.brush) };
            self.brush = null_mut();
        }
    }
}

impl OwnedApplyKeyline {
    fn replace_brush(&mut self, color: u32) -> io::Result<()> {
        // SAFETY: color is a validated integral COLORREF and the returned brush
        // remains solely owned until it is swapped below.
        let replacement = unsafe { CreateSolidBrush(color) };
        if replacement.is_null() {
            return Err(io::Error::last_os_error());
        }
        let previous = core::mem::replace(&mut self.brush, replacement);
        // SAFETY: window is live and now resolves the replacement brush before
        // the previous unselected brush is deleted.
        unsafe {
            InvalidateRect(self.window, null(), 1);
            DeleteObject(previous);
        }
        Ok(())
    }
}

/// Owns the native controls that render one side of the command rail.
pub(super) struct CommandRail {
    parent: HWND,
    spec: &'static CommandRailSpec,
    buttons: Vec<CommandButton>,
    separators: Vec<HWND>,
    apply_keyline: Option<OwnedApplyKeyline>,
    rail_visible: Cell<bool>,
    separators_requested: Cell<bool>,
    apply_keyline_requested: Cell<bool>,
    tooltip: OwnedTooltip,
    tooltip_texts: Vec<Box<[u16]>>,
}

impl CommandRail {
    pub(super) fn create(parent: HWND, spec: &'static CommandRailSpec) -> io::Result<Self> {
        let tooltip = create_tooltip(parent)?;
        let mut rail = Self {
            parent,
            spec,
            buttons: Vec::with_capacity(spec.command_count()),
            separators: Vec::with_capacity(spec.group_count().saturating_sub(1)),
            apply_keyline: None,
            rail_visible: Cell::new(true),
            separators_requested: Cell::new(true),
            apply_keyline_requested: Cell::new(false),
            tooltip,
            tooltip_texts: Vec::with_capacity(spec.command_count()),
        };

        if let Err(error) = rail.populate() {
            rail.destroy_partial();
            return Err(error);
        }
        Ok(rail)
    }

    fn populate(&mut self) -> io::Result<()> {
        for command in self.spec.commands() {
            let command_spec = command_ui_spec(command)
                .filter(|spec| spec.rail.is_some())
                .ok_or_else(|| io::Error::other("command rail label is missing"))?;
            let label = wide(command_spec.rail_label);
            // A standard BUTTON exposes this catalog-owned window text as its
            // accessible name; no parallel accessibility string can drift.
            // SAFETY: parent is a live top-level window, label is terminated
            // UTF-16 retained through the synchronous control creation call,
            // and the numeric child identifier is the stable command ID.
            let button = unsafe {
                CreateWindowExW(
                    0,
                    wide("BUTTON").as_ptr(),
                    label.as_ptr(),
                    WS_CHILD
                        | WS_VISIBLE
                        | BS_PUSHBUTTON as u32
                        | BS_NOTIFY as u32
                        | BS_MULTILINE as u32
                        | BS_CENTER as u32
                        | BS_VCENTER as u32,
                    0,
                    0,
                    0,
                    0,
                    self.parent,
                    usize::from(command) as *mut c_void,
                    GetModuleHandleW(null()),
                    null_mut(),
                )
            };
            if button.is_null() {
                return Err(io::Error::last_os_error());
            }
            self.buttons.push(CommandButton {
                command,
                window: button,
            });
            self.add_tooltip(button, command_spec.tooltip_label)?;
        }
        for _ in 1..self.spec.group_count() {
            // A themed STATIC separator is decorative and deliberately omits
            // WS_TABSTOP, an identifier, and custom drawing.
            // SAFETY: parent is a live top-level window and the system STATIC
            // class retains no caller-owned storage from this creation call.
            let separator = unsafe {
                CreateWindowExW(
                    0,
                    wide("STATIC").as_ptr(),
                    null(),
                    WS_CHILD | WS_VISIBLE | SS_ETCHEDHORZ,
                    0,
                    0,
                    0,
                    0,
                    self.parent,
                    null_mut(),
                    GetModuleHandleW(null()),
                    null_mut(),
                )
            };
            if separator.is_null() {
                return Err(io::Error::last_os_error());
            }
            self.separators.push(separator);
        }
        if self.spec.commands().any(|command| command == APPLY) {
            self.apply_keyline = Some(create_apply_keyline(self.parent)?);
        }
        Ok(())
    }

    fn add_tooltip(&mut self, button: HWND, tooltip_label: &str) -> io::Result<()> {
        let text = wide(tooltip_label).into_boxed_slice();
        // The V2 prefix excludes only lpReserved, which this application does
        // not use, and is accepted by both legacy and manifest-selected v6
        // tooltip controls. CCM_GETVERSION is deliberately not used here: it
        // reports the per-control behavior version, not the ComCtl DLL version.
        let tool_info_size = std::mem::offset_of!(TTTOOLINFOW, lpReserved);
        let mut tool = TTTOOLINFOW {
            // Common-controls before v6 rejects the final reserved pointer;
            // v6 accepts the complete structure used by the product manifest.
            cbSize: u32::try_from(tool_info_size)
                .map_err(|_| io::Error::other("invalid tooltip structure size"))?,
            uFlags: TTF_IDISHWND | TTF_SUBCLASS,
            hwnd: self.parent,
            uId: button as usize,
            lpszText: text.as_ptr().cast_mut(),
            ..TTTOOLINFOW::default()
        };
        // SAFETY: tooltip and button are live, tool has its exact structure
        // size, and text is heap-backed storage retained by this CommandRail.
        let added = unsafe {
            SendMessageW(
                self.tooltip.as_raw(),
                TTM_ADDTOOLW,
                0,
                (&mut tool as *mut TTTOOLINFOW) as isize,
            )
        };
        if added == 0 {
            return Err(io::Error::other("could not add command rail tooltip"));
        }
        self.tooltip_texts.push(text);
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn arrange(&self, origin_x: i32, placements: &[CommandPlacement], dpi: u32) {
        for placement in placements {
            let Some(button) = self.command_hwnd(placement.command) else {
                continue;
            };
            // SAFETY: button is a live direct child of parent. Coordinates are
            // checked by the platform-neutral layout calculator and copied.
            unsafe {
                SetWindowPos(
                    button,
                    null_mut(),
                    origin_x.saturating_add(placement.x),
                    placement.y,
                    placement.width,
                    placement.height,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
                )
            };
        }
        for (separator, rect) in self
            .separators
            .iter()
            .zip(calculate_command_rail_separator_layout(placements, dpi))
        {
            // SAFETY: separator is a live direct child owned by this rail and
            // the pure layout is bounded by its neighboring group buttons.
            unsafe {
                SetWindowPos(
                    *separator,
                    null_mut(),
                    origin_x.saturating_add(rect.x),
                    rect.y,
                    rect.width,
                    rect.height,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
                )
            };
        }
        if let (Some(keyline), Some(rect)) = (
            self.apply_keyline.as_ref(),
            calculate_apply_keyline_layout(placements, dpi),
        ) {
            // SAFETY: keyline.window is a live direct child and the pure rect
            // is bounded outside the Apply button hit target.
            unsafe {
                SetWindowPos(
                    keyline.window,
                    null_mut(),
                    origin_x.saturating_add(rect.x),
                    rect.y,
                    rect.width,
                    rect.height,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW,
                )
            };
        }
    }

    pub(super) fn append_placements(
        &self,
        origin_x: i32,
        placements: &[CommandPlacement],
        dpi: u32,
        windows: &mut Vec<(HWND, LayoutRect)>,
    ) {
        windows.extend(placements.iter().filter_map(|placement| {
            self.command_hwnd(placement.command).map(|window| {
                (
                    window,
                    LayoutRect {
                        x: origin_x.saturating_add(placement.x),
                        y: placement.y,
                        width: placement.width,
                        height: placement.height,
                    },
                )
            })
        }));
        windows.extend(
            self.separators
                .iter()
                .copied()
                .zip(calculate_command_rail_separator_layout(placements, dpi))
                .map(|(window, mut rect)| {
                    rect.x = rect.x.saturating_add(origin_x);
                    (window, rect)
                }),
        );
        if let (Some(keyline), Some(mut rect)) = (
            self.apply_keyline.as_ref(),
            calculate_apply_keyline_layout(placements, dpi),
        ) {
            rect.x = rect.x.saturating_add(origin_x);
            windows.push((keyline.window, rect));
        }
    }

    pub(super) fn set_enabled(&self, command: CommandId, enabled: bool) {
        if let Some(button) = self.command_hwnd(command) {
            // SAFETY: button is the live child control associated with command.
            unsafe { EnableWindow(button, enabled as i32) };
        }
    }

    pub(super) fn set_visible(&self, visible: bool) {
        self.rail_visible.set(visible);
        let command = if visible { SW_SHOW } else { SW_HIDE };
        for button in &self.buttons {
            // SAFETY: each button is a live child owned by this command rail.
            unsafe { ShowWindow(button.window, command) };
        }
        self.update_separator_visibility();
        self.update_apply_keyline_visibility();
    }

    pub(super) fn set_separators_visible(&self, visible: bool) {
        self.separators_requested.set(visible);
        self.update_separator_visibility();
    }

    fn update_separator_visibility(&self) {
        let visible = self.rail_visible.get() && self.separators_requested.get();
        for separator in &self.separators {
            // SAFETY: each separator is a live decorative child owned by this rail.
            unsafe { ShowWindow(*separator, if visible { SW_SHOW } else { SW_HIDE }) };
        }
    }

    pub(super) fn set_apply_keyline_visible(&self, visible: bool) {
        self.apply_keyline_requested.set(visible);
        self.update_apply_keyline_visibility();
    }

    fn update_apply_keyline_visibility(&self) {
        let Some(keyline) = &self.apply_keyline else {
            return;
        };
        let visible = self.rail_visible.get() && self.apply_keyline_requested.get();
        // SAFETY: keyline.window is the live decorative STATIC owned by this rail.
        unsafe { ShowWindow(keyline.window, if visible { SW_SHOW } else { SW_HIDE }) };
    }

    pub(super) fn apply_keyline_brush_for(&self, window: HWND) -> Option<HBRUSH> {
        self.apply_keyline
            .as_ref()
            .filter(|keyline| keyline.window == window)
            .map(|keyline| keyline.brush)
    }

    pub(super) fn set_apply_keyline_color(&mut self, color: u32) -> io::Result<()> {
        self.apply_keyline
            .as_mut()
            .map_or(Ok(()), |keyline| keyline.replace_brush(color))
    }

    pub(super) fn apply_font(&self, font: HFONT) {
        for button in &self.buttons {
            // SAFETY: each button is live and font remains AppState-owned until
            // every control receives a replacement or is destroyed.
            unsafe { SendMessageW(button.window, WM_SETFONT, font as usize, 1) };
        }
    }

    pub(super) fn command_hwnd(&self, command: CommandId) -> Option<HWND> {
        self.buttons
            .iter()
            .find(|button| button.command == command)
            .map(|button| button.window)
    }

    pub(super) fn hwnd_at(&self, index: usize) -> Option<HWND> {
        self.buttons.get(index).map(|button| button.window)
    }

    pub(super) fn index_for_hwnd(&self, window: HWND) -> Option<usize> {
        self.buttons
            .iter()
            .position(|button| button.window == window)
    }

    pub(super) fn set_tab_stop(&self, active_index: Option<usize>) {
        for (index, button) in self.buttons.iter().enumerate() {
            // SAFETY: each button is a live process-owned child and GWL_STYLE
            // reads/writes only its integral style word.
            let style = unsafe { GetWindowLongPtrW(button.window, GWL_STYLE) };
            let tab_stop = isize::try_from(WS_TABSTOP).unwrap_or_default();
            let next = if Some(index) == active_index {
                style | tab_stop
            } else {
                style & !tab_stop
            };
            if next != style {
                // SAFETY: same live button and integral style value as above.
                unsafe { SetWindowLongPtrW(button.window, GWL_STYLE, next) };
            }
        }
    }

    fn destroy_partial(&mut self) {
        self.tooltip.destroy();
        drop(self.apply_keyline.take());
        for separator in self.separators.drain(..) {
            // SAFETY: this rail owns each still-live decorative child.
            unsafe { DestroyWindow(separator) };
        }
        for button in self.buttons.drain(..) {
            // SAFETY: partial construction created this still-live child and no
            // successful CommandRail can observe it after this error cleanup.
            unsafe { DestroyWindow(button.window) };
        }
    }

    pub(super) fn destroy(mut self) {
        self.destroy_partial();
    }

    #[cfg(test)]
    pub(super) fn button_count(&self) -> usize {
        self.buttons.len()
    }

    #[cfg(test)]
    pub(super) fn separator_windows(&self) -> &[HWND] {
        &self.separators
    }

    #[cfg(test)]
    pub(super) fn apply_keyline_window(&self) -> Option<HWND> {
        self.apply_keyline.as_ref().map(|keyline| keyline.window)
    }

    #[cfg(test)]
    pub(super) fn apply_keyline_brush(&self) -> Option<HBRUSH> {
        self.apply_keyline.as_ref().map(|keyline| keyline.brush)
    }

    #[cfg(test)]
    pub(super) fn apply_keyline_rect(&self) -> io::Result<RECT> {
        let keyline = self
            .apply_keyline
            .as_ref()
            .ok_or_else(|| io::Error::other("Apply keyline is missing"))?;
        let mut rect = RECT::default();
        // SAFETY: keyline.window is live and rect is writable for this query.
        if unsafe { GetWindowRect(keyline.window, &mut rect) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: rect is two POINT-compatible coordinate pairs and parent is
        // the live target coordinate space.
        unsafe { MapWindowPoints(null_mut(), self.parent, (&mut rect as *mut RECT).cast(), 2) };
        Ok(rect)
    }

    #[cfg(test)]
    pub(super) fn separator_rect(&self, index: usize) -> io::Result<RECT> {
        let separator = self
            .separators
            .get(index)
            .copied()
            .ok_or_else(|| io::Error::other("command rail separator is missing"))?;
        let mut rect = RECT::default();
        // SAFETY: separator is live and rect is writable for this query.
        if unsafe { GetWindowRect(separator, &mut rect) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: rect is two consecutive POINT-compatible coordinate pairs;
        // parent is the live client-coordinate target.
        unsafe { MapWindowPoints(null_mut(), self.parent, (&mut rect as *mut RECT).cast(), 2) };
        Ok(rect)
    }

    #[cfg(test)]
    pub(super) fn command_rect(&self, command: CommandId) -> io::Result<RECT> {
        let button = self
            .command_hwnd(command)
            .ok_or_else(|| io::Error::other("command rail button is missing"))?;
        let mut rect = RECT::default();
        // SAFETY: button is live and rect is writable for the synchronous query.
        if unsafe { GetWindowRect(button, &mut rect) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: rect is two consecutive POINT-compatible coordinate pairs;
        // null means desktop coordinates and parent is the live target client.
        unsafe { MapWindowPoints(null_mut(), self.parent, (&mut rect as *mut RECT).cast(), 2) };
        Ok(rect)
    }
}

fn create_tooltip(parent: HWND) -> io::Result<OwnedTooltip> {
    // SAFETY: parent is live, the common-control class is process-global, and
    // tooltip creation retains no caller-owned text or creation parameter.
    let tooltip = unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            TOOLTIPS_CLASSW,
            null(),
            WS_POPUP | TTS_ALWAYSTIP,
            0,
            0,
            0,
            0,
            parent,
            null_mut(),
            GetModuleHandleW(null()),
            null_mut(),
        )
    };
    if tooltip.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(OwnedTooltip(tooltip))
    }
}

fn create_apply_keyline(parent: HWND) -> io::Result<OwnedApplyKeyline> {
    // SAFETY: the COLORREF is an integral constant and the returned brush is
    // owned by the wrapper below.
    let brush = unsafe { CreateSolidBrush(APPLY_KEYLINE_COLOR) };
    if brush.is_null() {
        return Err(io::Error::last_os_error());
    }
    // An empty standard STATIC uses the parent-provided WM_CTLCOLORSTATIC brush
    // as its background. It has no identifier, notifications, or focus style.
    // SAFETY: parent is live, the system class is process-global, and no caller
    // storage is retained by this direct-child creation.
    let window = unsafe {
        CreateWindowExW(
            0,
            wide("STATIC").as_ptr(),
            null(),
            WS_CHILD,
            0,
            0,
            0,
            0,
            parent,
            null_mut(),
            GetModuleHandleW(null()),
            null_mut(),
        )
    };
    if window.is_null() {
        // SAFETY: brush is the still-unshared object created above.
        unsafe { DeleteObject(brush) };
        return Err(io::Error::last_os_error());
    }
    Ok(OwnedApplyKeyline { window, brush })
}
