use std::ffi::c_void;
use std::io;
use std::mem::size_of;
use std::ptr::{null, null_mut};

use ::windows::UI::ViewManagement::{UIColorType, UISettings};
use ::windows::Win32::System::WinRT::{RO_INIT_SINGLETHREADED, RoInitialize, RoUninitialize};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
use windows_sys::Win32::Graphics::Gdi::{
    COLOR_WINDOW, COLOR_WINDOWTEXT, CreateSolidBrush, DeleteObject, GetSysColor, HBRUSH,
    RDW_ALLCHILDREN, RDW_ERASE, RDW_INVALIDATE, RedrawWindow,
};
use windows_sys::Win32::UI::Controls::{LVM_SETBKCOLOR, LVM_SETTEXTBKCOLOR, LVM_SETTEXTCOLOR};
use windows_sys::Win32::UI::WindowsAndMessaging::SendMessageW;

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
    workspace: OwnedSolidBrush,
    status: OwnedSolidBrush,
    drop_overlay: OwnedSolidBrush,
    palette: SemanticPalette,
}

impl AppearanceResources {
    fn create(palette: SemanticPalette) -> io::Result<Self> {
        Ok(Self {
            workspace: OwnedSolidBrush::create(palette.surface_workspace)?,
            status: OwnedSolidBrush::create(palette.surface_status)?,
            drop_overlay: OwnedSolidBrush::create(palette.surface_drop)?,
            palette,
        })
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
