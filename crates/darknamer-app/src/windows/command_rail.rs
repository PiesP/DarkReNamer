use std::cell::Cell;
use std::ffi::c_void;
use std::io;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::{HWND, LPARAM, RECT};
#[cfg(test)]
use windows_sys::Win32::Graphics::Gdi::MapWindowPoints;
use windows_sys::Win32::Graphics::Gdi::{HFONT, InvalidateRect};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
#[cfg(test)]
use windows_sys::Win32::System::SystemServices::MK_LBUTTON;
use windows_sys::Win32::System::SystemServices::SS_OWNERDRAW;
use windows_sys::Win32::UI::Controls::WM_MOUSELEAVE;
use windows_sys::Win32::UI::Controls::{
    TOOLTIPS_CLASSW, TTF_IDISHWND, TTF_SUBCLASS, TTM_ADDTOOLW, TTS_ALWAYSTIP, TTTOOLINFOW,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent,
};
use windows_sys::Win32::UI::Shell::{
    DefSubclassProc, GetWindowSubclass, RemoveWindowSubclass, SetWindowSubclass,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::GetWindowRect;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BS_CENTER, BS_MULTILINE, BS_NOTIFY, BS_OWNERDRAW, BS_PUSHBUTTON, BS_VCENTER, CreateWindowExW,
    DestroyWindow, GWL_STYLE, GetClientRect, GetWindowLongPtrW, SW_HIDE, SW_SHOW, SendMessageW,
    SetWindowLongPtrW, ShowWindow, WM_CANCELMODE, WM_CAPTURECHANGED, WM_ENABLE, WM_MOUSEMOVE,
    WM_NCDESTROY, WM_SETFONT, WM_SHOWWINDOW, WS_CHILD, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    WS_TABSTOP, WS_VISIBLE,
};
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::{
    SWP_NOACTIVATE, SWP_NOREDRAW, SWP_NOZORDER, SetWindowPos, WM_LBUTTONDOWN, WM_LBUTTONUP,
    WM_SETFOCUS,
};

use super::{
    APPLY, AppearanceResources, CommandId, CommandPlacement, CommandRailSpec, LayoutRect,
    SeparatorSurface, calculate_command_rail_separator_layout, command_ui_spec,
    draw_owner_separator, wide,
};

const RAIL_HOVER_SUBCLASS_ID: usize = 0xD4B6;

fn install_rail_hover_subclass(button: HWND) -> io::Result<()> {
    // SAFETY: this live UI-thread child owns the scalar hover subclass until
    // WM_NCDESTROY; partial construction destroys the child too.
    if unsafe { SetWindowSubclass(button, Some(rail_hover_subclass), RAIL_HOVER_SUBCLASS_ID, 0) }
        == 0
    {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub(super) fn is_rail_button_hot(button: HWND) -> bool {
    let mut hot = 0;
    // SAFETY: the caller supplies a live UI-thread button. The subclass stores
    // only a scalar bit, so no borrowed allocation can outlive its owner.
    let installed = unsafe {
        GetWindowSubclass(
            button,
            Some(rail_hover_subclass),
            RAIL_HOVER_SUBCLASS_ID,
            &mut hot,
        ) != 0
    };
    installed && hot != 0
}

fn mouse_inside_client(button: HWND, lparam: LPARAM) -> bool {
    let mut client = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    // SAFETY: this callback receives the live UI-thread BUTTON HWND. A failed
    // query clears cosmetic hover rather than retaining a possibly stale fill.
    if unsafe { GetClientRect(button, &mut client) } == 0 {
        return false;
    }
    let packed = lparam as u32;
    let x = (packed as u16 as i16) as i32;
    let y = ((packed >> 16) as u16 as i16) as i32;
    x >= client.left && x < client.right && y >= client.top && y < client.bottom
}

unsafe extern "system" fn rail_hover_subclass(
    button: HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
    subclass_id: usize,
    ref_data: usize,
) -> isize {
    if subclass_id == RAIL_HOVER_SUBCLASS_ID {
        match message {
            WM_MOUSEMOVE => {
                if !mouse_inside_client(button, lparam) {
                    // A BUTTON with mouse capture receives outside-client moves
                    // without necessarily receiving WM_MOUSELEAVE.
                    if ref_data != 0 {
                        // SAFETY: the live UI-thread child owns this exact
                        // subclass and only its scalar refdata is updated.
                        if unsafe {
                            SetWindowSubclass(button, Some(rail_hover_subclass), subclass_id, 0)
                        } != 0
                        {
                            // SAFETY: owner drawing fills the complete child later.
                            unsafe { InvalidateRect(button, null(), 0) };
                        }
                    }
                } else if ref_data == 0 {
                    let mut tracking = TRACKMOUSEEVENT {
                        cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: button,
                        dwHoverTime: 0,
                    };
                    // SAFETY: button is the live child receiving this mouse
                    // message; tracking retains the HWND, not this stack value.
                    if unsafe { TrackMouseEvent(&mut tracking) } != 0 {
                        // SAFETY: updating this exact installed proc/id replaces
                        // only scalar refdata on the live UI-thread child.
                        if unsafe {
                            SetWindowSubclass(button, Some(rail_hover_subclass), subclass_id, 1)
                        } != 0
                        {
                            // SAFETY: owner drawing fills the complete child later.
                            unsafe { InvalidateRect(button, null(), 0) };
                        }
                    }
                }
            }
            WM_MOUSELEAVE | WM_CAPTURECHANGED | WM_CANCELMODE | WM_SHOWWINDOW | WM_ENABLE
                if ref_data != 0
                    && (message == WM_MOUSELEAVE
                        || message == WM_CAPTURECHANGED
                        || message == WM_CANCELMODE
                        || wparam == 0) =>
            {
                // SAFETY: the child remains live during these notifications;
                // only the scalar hot state is cleared.
                if unsafe { SetWindowSubclass(button, Some(rail_hover_subclass), subclass_id, 0) }
                    != 0
                {
                    // SAFETY: no synchronous parent paint is requested here.
                    unsafe { InvalidateRect(button, null(), 0) };
                }
            }
            WM_NCDESTROY => {
                // SAFETY: this is the child subclass's terminal message. Remove
                // its exact registration before forwarding native destruction.
                unsafe { RemoveWindowSubclass(button, Some(rail_hover_subclass), subclass_id) };
            }
            _ => {}
        }
    }
    // SAFETY: every message retains the BUTTON's native processing and the
    // remaining common-controls subclass chain exactly once.
    unsafe { DefSubclassProc(button, message, wparam, lparam) }
}

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

/// Owns the native controls that render one side of the command rail.
pub(super) struct CommandRail {
    parent: HWND,
    spec: &'static CommandRailSpec,
    buttons: Vec<CommandButton>,
    separators: Vec<HWND>,
    rail_visible: Cell<bool>,
    separators_requested: Cell<bool>,
    apply_readiness_requested: Cell<bool>,
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
            rail_visible: Cell::new(true),
            separators_requested: Cell::new(true),
            apply_readiness_requested: Cell::new(false),
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
            let label = wide(command_spec.menu_label);
            // A standard BUTTON exposes the full menu command as its accessible
            // name. Owner-draw painting resolves the shorter rail label from
            // the same command ID, so narrow visual copy cannot truncate the
            // spoken name.
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
                        | BS_OWNERDRAW as u32
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
            install_rail_hover_subclass(button)?;
            self.add_tooltip(button, command_spec.tooltip_label)?;
        }
        for _ in 1..self.spec.group_count() {
            // An owner-drawn STATIC separator is decorative and deliberately
            // omits WS_TABSTOP and an identifier. Owning the complete two-DIP
            // paint avoids the system etched renderer's light background in a
            // custom dark palette while retaining system-color fallback.
            // SAFETY: parent is a live top-level window and the system STATIC
            // class retains no caller-owned storage from this creation call.
            let separator = unsafe {
                CreateWindowExW(
                    0,
                    wide("STATIC").as_ptr(),
                    null(),
                    WS_CHILD | WS_VISIBLE | SS_OWNERDRAW,
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
    }

    pub(super) fn set_enabled(&self, command: CommandId, enabled: bool) {
        if let Some(button) = self.command_hwnd(command) {
            // SAFETY: button is the live child control associated with command.
            // Invalidation only schedules paint after the current AppState lease
            // ends; EnableWindow can request synchronous owner drawing while that
            // lease prevents the parent from handling WM_DRAWITEM.
            unsafe {
                // EnableWindow reports whether the button was previously disabled.
                let was_enabled = EnableWindow(button, enabled as i32) == 0;
                if was_enabled != enabled {
                    InvalidateRect(button, null(), 0);
                }
            }
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
        self.invalidate_apply_readiness();
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

    pub(super) fn set_apply_readiness_visible(&self, visible: bool) {
        if self.apply_readiness_requested.replace(visible) != visible {
            self.invalidate_apply_readiness();
        }
    }

    fn invalidate_apply_readiness(&self) {
        if let Some(apply) = self.command_hwnd(APPLY) {
            // SAFETY: Apply is the live owner-draw child owned by this rail;
            // erasing is unnecessary because the button paint fills its rect.
            unsafe { InvalidateRect(apply, null(), 0) };
        }
    }

    pub(super) fn active_apply_readiness_button(&self) -> Option<HWND> {
        (self.rail_visible.get() && self.apply_readiness_requested.get())
            .then(|| self.command_hwnd(APPLY))
            .flatten()
    }

    pub(super) fn draw_separator(
        &self,
        resources: Option<&AppearanceResources>,
        lparam: LPARAM,
    ) -> bool {
        self.separators.iter().any(|separator| {
            draw_owner_separator(resources, *separator, SeparatorSurface::Window, lparam)
        })
    }

    pub(super) fn apply_font(&self, font: HFONT) {
        for button in &self.buttons {
            // SAFETY: each button is live and font remains AppState-owned until
            // every control receives a replacement or is destroyed.
            unsafe { SendMessageW(button.window, WM_SETFONT, font as usize, 1) };
        }
    }

    pub(super) fn tooltip_window(&self) -> HWND {
        self.tooltip.as_raw()
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

#[cfg(test)]
mod native_tests {
    use super::*;
    use windows_sys::Win32::UI::WindowsAndMessaging::WS_OVERLAPPEDWINDOW;

    fn mouse_lparam(x: i16, y: i16) -> LPARAM {
        ((x as u16 as u32) | ((y as u16 as u32) << 16)) as LPARAM
    }

    fn send_button_test_message(button: HWND, message: u32, wparam: usize, lparam: LPARAM) {
        // SAFETY: each test calls this only while its owned native BUTTON child
        // is live, on the same thread that created the child and its subclass.
        unsafe { SendMessageW(button, message, wparam, lparam) };
    }

    struct TestWindow(HWND);

    impl Drop for TestWindow {
        fn drop(&mut self) {
            // SAFETY: this test solely owns the parent and all its child HWNDs.
            unsafe { DestroyWindow(self.0) };
        }
    }

    #[test]
    fn rail_button_hover_follows_mouse_leave_and_control_lifetime() -> io::Result<()> {
        // SAFETY: the system STATIC class and module handle are process-global;
        // TestWindow destroys this local parent on every exit path.
        let parent = unsafe {
            CreateWindowExW(
                0,
                wide("STATIC").as_ptr(),
                null(),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                100,
                100,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if parent.is_null() {
            return Err(io::Error::last_os_error());
        }
        let parent = TestWindow(parent);
        // SAFETY: the parent remains owned and live throughout the test; its
        // destruction also destroys this standard BUTTON child.
        let button = unsafe {
            CreateWindowExW(
                0,
                wide("BUTTON").as_ptr(),
                null(),
                WS_CHILD | WS_VISIBLE | BS_OWNERDRAW as u32,
                0,
                0,
                64,
                40,
                parent.0,
                null_mut(),
                GetModuleHandleW(null()),
                null_mut(),
            )
        };
        if button.is_null() {
            return Err(io::Error::last_os_error());
        }
        install_rail_hover_subclass(button)?;
        assert!(!is_rail_button_hot(button));
        // SAFETY: synchronous test messages exercise the installed subclass;
        // TrackMouseEvent posts an actual leave if the cursor is elsewhere.
        unsafe { SendMessageW(button, WM_MOUSEMOVE, 0, 0) };
        assert!(is_rail_button_hot(button));
        // Native button messages model a captured press, an inside move, an
        // outside move with signed client coordinates, then release and focus.
        send_button_test_message(
            button,
            WM_LBUTTONDOWN,
            MK_LBUTTON as usize,
            mouse_lparam(8, 8),
        );
        send_button_test_message(
            button,
            WM_MOUSEMOVE,
            MK_LBUTTON as usize,
            mouse_lparam(8, 8),
        );
        assert!(is_rail_button_hot(button));
        send_button_test_message(
            button,
            WM_MOUSEMOVE,
            MK_LBUTTON as usize,
            mouse_lparam(-3, 8),
        );
        assert!(!is_rail_button_hot(button));
        send_button_test_message(button, WM_LBUTTONUP, 0, mouse_lparam(-3, 8));
        send_button_test_message(button, WM_SETFOCUS, 0, 0);
        assert!(!is_rail_button_hot(button));
        // Capture loss and canceled gestures also discard stale cosmetic hover.
        send_button_test_message(button, WM_MOUSEMOVE, 0, mouse_lparam(8, 8));
        assert!(is_rail_button_hot(button));
        send_button_test_message(button, WM_CAPTURECHANGED, 0, 0);
        assert!(!is_rail_button_hot(button));
        send_button_test_message(button, WM_MOUSEMOVE, 0, mouse_lparam(8, 8));
        assert!(is_rail_button_hot(button));
        send_button_test_message(button, WM_CANCELMODE, 0, 0);
        assert!(!is_rail_button_hot(button));
        send_button_test_message(button, WM_MOUSEMOVE, 0, mouse_lparam(8, 8));
        assert!(is_rail_button_hot(button));
        // SAFETY: this is the documented leave notification for this child.
        unsafe { SendMessageW(button, WM_MOUSELEAVE, 0, 0) };
        assert!(!is_rail_button_hot(button));
        // SAFETY: disabling a live BUTTON must clear any retained hot state.
        unsafe {
            SendMessageW(button, WM_MOUSEMOVE, 0, 0);
            EnableWindow(button, 0);
        }
        assert!(!is_rail_button_hot(button));
        // SAFETY: parent destruction delivers WM_NCDESTROY to the child and
        // detaches the subclass before the test-owned HWND ceases to exist.
        drop(parent);
        Ok(())
    }
}
