use std::ffi::c_void;
use std::io;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::HWND;
#[cfg(test)]
use windows_sys::Win32::Foundation::RECT;
use windows_sys::Win32::Graphics::Gdi::HFONT;
#[cfg(test)]
use windows_sys::Win32::Graphics::Gdi::MapWindowPoints;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::{
    TOOLTIPS_CLASSW, TTF_IDISHWND, TTF_SUBCLASS, TTM_ADDTOOLW, TTS_ALWAYSTIP, TTTOOLINFOW,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
#[cfg(test)]
use windows_sys::Win32::UI::WindowsAndMessaging::GetWindowRect;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BS_CENTER, BS_FLAT, BS_MULTILINE, BS_PUSHBUTTON, BS_VCENTER, CreateWindowExW, DestroyWindow,
    MoveWindow, SW_HIDE, SW_SHOW, SendMessageW, ShowWindow, WM_SETFONT, WS_CHILD, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP, WS_TABSTOP, WS_VISIBLE,
};

use super::{CommandId, CommandPlacement, CommandRailSpec, ToolSpec, wide};

#[derive(Debug)]
struct CommandButton {
    command: CommandId,
    window: HWND,
}

/// Owns the native controls that render one side of the command rail.
pub(super) struct CommandRail {
    parent: HWND,
    spec: &'static CommandRailSpec,
    buttons: Vec<CommandButton>,
    tooltip: HWND,
    tooltip_texts: Vec<Box<[u16]>>,
}

impl CommandRail {
    pub(super) fn create(
        parent: HWND,
        spec: &'static CommandRailSpec,
        tools: &'static [ToolSpec],
    ) -> io::Result<Self> {
        let tooltip = create_tooltip(parent)?;
        let mut rail = Self {
            parent,
            spec,
            buttons: Vec::with_capacity(spec.command_count()),
            tooltip,
            tooltip_texts: Vec::with_capacity(spec.command_count()),
        };

        if let Err(error) = rail.populate(tools) {
            rail.destroy_partial();
            return Err(error);
        }
        Ok(rail)
    }

    fn populate(&mut self, tools: &'static [ToolSpec]) -> io::Result<()> {
        for command in self.spec.commands() {
            let tool = tools
                .iter()
                .find(|tool| tool.id == command)
                .ok_or_else(|| io::Error::other("command rail label is missing"))?;
            let label = wide(tool.label);
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
                        | WS_TABSTOP
                        | BS_PUSHBUTTON as u32
                        | BS_MULTILINE as u32
                        | BS_FLAT as u32
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
            self.add_tooltip(button, *tool)?;
        }
        Ok(())
    }

    fn add_tooltip(&mut self, button: HWND, tool_spec: ToolSpec) -> io::Result<()> {
        let text = wide(&tool_spec.one_line_label()).into_boxed_slice();
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
                self.tooltip,
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

    pub(super) fn arrange(&self, origin_x: i32, placements: &[CommandPlacement]) {
        for placement in placements {
            let Some(button) = self.command_hwnd(placement.command) else {
                continue;
            };
            // SAFETY: button is a live direct child of parent. Coordinates are
            // checked by the platform-neutral layout calculator and copied.
            unsafe {
                MoveWindow(
                    button,
                    origin_x.saturating_add(placement.x),
                    placement.y,
                    placement.width,
                    placement.height,
                    1,
                )
            };
        }
    }

    pub(super) fn set_enabled(&self, command: CommandId, enabled: bool) {
        if let Some(button) = self.command_hwnd(command) {
            // SAFETY: button is the live child control associated with command.
            unsafe { EnableWindow(button, enabled as i32) };
        }
    }

    pub(super) fn set_visible(&self, visible: bool) {
        let command = if visible { SW_SHOW } else { SW_HIDE };
        for button in &self.buttons {
            // SAFETY: each button is a live child owned by this command rail.
            unsafe { ShowWindow(button.window, command) };
        }
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

    fn destroy_partial(&mut self) {
        if !self.tooltip.is_null() {
            // SAFETY: partial construction created this tooltip and destroys it
            // before releasing any text buffers referenced by its tools.
            unsafe { DestroyWindow(self.tooltip) };
            self.tooltip = null_mut();
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

fn create_tooltip(parent: HWND) -> io::Result<HWND> {
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
        Ok(tooltip)
    }
}
