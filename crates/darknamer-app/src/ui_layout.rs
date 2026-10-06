#![forbid(unsafe_code)]

use crate::BASE_DPI;
#[cfg(any(windows, test))]
use crate::STATUS_HEIGHT;
#[cfg(any(windows, test))]
use crate::command_catalog::{APPLY, command_ui_spec};
use crate::command_catalog::{CommandId, CommandRailSpec, LEFT_RAIL, RIGHT_RAIL};
#[cfg(any(windows, test))]
use crate::{
    EMPTY_STATE_SAFETY, EMPTY_STATE_SAFETY_RAILS, LIST_COLUMN_FIT_GUTTER_DIP,
    LOCATION_COLUMN_MINIMUM, NAME_COLUMN_MINIMUM, NATIVE_STATUS_COLUMN_WIDTH_DIP,
};

/// Scales one 96-DPI logical coordinate with nearest-integer rounding.
#[must_use]
pub const fn scale_dip(value: i32, dpi: u32) -> i32 {
    let product = (value as i128) * (dpi as i128);
    let scaled = if product < 0 {
        -((-product + (BASE_DPI / 2) as i128) / BASE_DPI as i128)
    } else {
        (product + (BASE_DPI / 2) as i128) / BASE_DPI as i128
    };
    if scaled > i32::MAX as i128 {
        i32::MAX
    } else if scaled < i32::MIN as i128 {
        i32::MIN
    } else {
        scaled as i32
    }
}

/// Scales a GDI font height for the Windows system text-size preference.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn scale_system_font_height(height: i32, text_scale_factor: f64) -> i32 {
    if !(1.0..=2.25).contains(&text_scale_factor) {
        return height;
    }
    let scaled = f64::from(height) * text_scale_factor;
    if scaled >= f64::from(i32::MAX) {
        i32::MAX
    } else if scaled <= f64::from(i32::MIN) {
        i32::MIN
    } else {
        scaled.round() as i32
    }
}

/// Supported command-rail density.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RailDensity {
    Comfortable,
    Compact,
}

/// Persisted command-rail density preference.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum RailDensityPreference {
    #[default]
    Automatic,
    Comfortable,
    Compact,
    MenuOnly,
}

impl RailDensityPreference {
    const AUTOMATIC_CANDIDATES: [RailDensity; 2] = [RailDensity::Comfortable, RailDensity::Compact];
    const COMFORTABLE_CANDIDATES: [RailDensity; 1] = [RailDensity::Comfortable];
    const COMPACT_CANDIDATES: [RailDensity; 1] = [RailDensity::Compact];
    const MENU_ONLY_CANDIDATES: [RailDensity; 0] = [];

    #[must_use]
    const fn candidates(self) -> &'static [RailDensity] {
        match self {
            Self::Automatic => &Self::AUTOMATIC_CANDIDATES,
            Self::Comfortable => &Self::COMFORTABLE_CANDIDATES,
            Self::Compact => &Self::COMPACT_CANDIDATES,
            Self::MenuOnly => &Self::MENU_ONLY_CANDIDATES,
        }
    }

    #[must_use]
    pub(crate) const fn minimum_density(self) -> Option<RailDensity> {
        match self {
            Self::Automatic | Self::Compact => Some(RailDensity::Compact),
            Self::Comfortable => Some(RailDensity::Comfortable),
            Self::MenuOnly => None,
        }
    }

    #[must_use]
    #[cfg(any(windows, test))]
    const fn recommended_density(self) -> Option<RailDensity> {
        match self {
            Self::Automatic | Self::Comfortable => Some(RailDensity::Comfortable),
            Self::Compact => Some(RailDensity::Compact),
            Self::MenuOnly => None,
        }
    }
}

/// Bounded control rectangles for the native advanced-appearance dialog.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct AppearanceDialogLayout {
    pub(crate) client: LayoutRect,
    pub(crate) body_viewport: LayoutRect,
    pub(crate) body_content_height: i32,
    pub(crate) scroll_max: i32,
    pub(crate) scroll_page: i32,
    pub(crate) footer: LayoutRect,
    pub(crate) compact_footer: bool,
    pub(crate) density_group: LayoutRect,
    pub(crate) density_options: [LayoutRect; 4],
    pub(crate) emphasis_group: LayoutRect,
    pub(crate) emphasis_options: [LayoutRect; 3],
    pub(crate) forced_explanation: LayoutRect,
    pub(crate) checkboxes: [LayoutRect; 3],
    pub(crate) separator: LayoutRect,
    pub(crate) reset: LayoutRect,
    pub(crate) ok: LayoutRect,
    pub(crate) cancel: LayoutRect,
}

/// Text measurements that let the appearance dialog grow with system fonts.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct AppearanceDialogMetrics {
    pub(crate) text_height: i32,
    pub(crate) widest_option: i32,
    pub(crate) widest_checkbox: i32,
    pub(crate) button_text_height: i32,
    pub(crate) widest_button: i32,
    pub(crate) wrapped_option_height: i32,
    pub(crate) wrapped_checkbox_height: i32,
    pub(crate) forced_explanation_height: i32,
}

#[cfg(any(windows, test))]
#[must_use]
fn bounded_dialog_rect(x: i32, y: i32, width: i32, height: i32, bounds: LayoutRect) -> LayoutRect {
    let x = x.max(0).min(bounds.width);
    let y = y.max(0).min(bounds.height);
    LayoutRect {
        x,
        y,
        width: width.max(0).min(bounds.width.saturating_sub(x)),
        height: height.max(0).min(bounds.height.saturating_sub(y)),
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn clamp_appearance_dialog_scroll(
    layout: AppearanceDialogLayout,
    scroll_y: i32,
) -> i32 {
    if scroll_y < 0 {
        0
    } else if scroll_y > layout.scroll_max {
        layout.scroll_max
    } else {
        scroll_y
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_appearance_dialog_layout(
    dpi: u32,
    maximum_width: i32,
    maximum_height: i32,
    show_forced_explanation: bool,
    measured: AppearanceDialogMetrics,
) -> Option<AppearanceDialogLayout> {
    let button_width =
        scale_dip(72, dpi).max(measured.widest_button.saturating_add(scale_dip(24, dpi)));
    let reset_width = scale_dip(124, dpi).max(button_width);
    let button_row_width = scale_dip(24, dpi)
        .saturating_add(reset_width)
        .saturating_add(button_width.saturating_mul(2))
        .saturating_add(scale_dip(16, dpi));
    let desired_width = scale_dip(456, dpi)
        .max(measured.widest_option.saturating_add(scale_dip(64, dpi)))
        .max(measured.widest_checkbox.saturating_add(scale_dip(48, dpi)))
        .max(button_row_width);
    let minimum_width = scale_dip(240, dpi).max(horizontal_footer_minimum_width(dpi, button_width));
    if maximum_width < minimum_width || maximum_height <= 0 {
        return None;
    }
    let client_width = desired_width.min(maximum_width);
    let row_height = scale_dip(20, dpi)
        .max(measured.text_height.saturating_add(scale_dip(6, dpi)))
        .max(
            measured
                .wrapped_option_height
                .saturating_add(scale_dip(4, dpi)),
        );
    let row_stride = row_height.saturating_add(scale_dip(2, dpi));
    let density_group_height = scale_dip(22, dpi).saturating_add(row_stride.saturating_mul(4));
    let emphasis_group_height = scale_dip(22, dpi).saturating_add(row_stride.saturating_mul(3));
    let checkbox_height = scale_dip(22, dpi)
        .max(measured.text_height.saturating_add(scale_dip(6, dpi)))
        .max(
            measured
                .wrapped_checkbox_height
                .saturating_add(scale_dip(4, dpi)),
        );
    let checkbox_stride = checkbox_height.saturating_add(scale_dip(6, dpi));
    let explanation_height = if show_forced_explanation {
        scale_dip(40, dpi)
            .max(measured.text_height.saturating_mul(2))
            .max(measured.forced_explanation_height)
    } else {
        0
    };
    let explanation_band = if show_forced_explanation {
        explanation_height.saturating_add(scale_dip(8, dpi))
    } else {
        0
    };
    let button_height = scale_dip(30, dpi).max(
        measured
            .button_text_height
            .saturating_add(scale_dip(12, dpi)),
    );
    let horizontal_margin = scale_dip(12, dpi);
    let density_y = horizontal_margin;
    let emphasis_y = density_y
        .saturating_add(density_group_height)
        .saturating_add(scale_dip(6, dpi));
    let content_y = emphasis_y
        .saturating_add(emphasis_group_height)
        .saturating_add(scale_dip(6, dpi));
    let checkbox_y = content_y.saturating_add(explanation_band);
    let separator_y = checkbox_y
        .saturating_add(checkbox_stride.saturating_mul(3))
        .saturating_add(scale_dip(4, dpi));
    let body_content_height = separator_y
        .saturating_add(scale_dip(1, dpi))
        .saturating_add(scale_dip(12, dpi));
    let available_footer_width = client_width.saturating_sub(horizontal_margin.saturating_mul(2));
    let compact_footer =
        available_footer_width < button_row_width.saturating_sub(scale_dip(24, dpi));
    let footer_height = if compact_footer {
        button_height
            .saturating_mul(2)
            .saturating_add(scale_dip(26, dpi))
    } else {
        button_height.saturating_add(scale_dip(18, dpi))
    };
    let minimum_viewport_height = scale_dip(48, dpi);
    if maximum_height < footer_height.saturating_add(minimum_viewport_height) {
        return None;
    }
    let desired_height = body_content_height.saturating_add(footer_height);
    let client_height = desired_height.min(maximum_height);
    let client = LayoutRect {
        x: 0,
        y: 0,
        width: client_width,
        height: client_height,
    };
    let body_viewport = LayoutRect {
        x: 0,
        y: 0,
        width: client_width,
        height: client_height.saturating_sub(footer_height),
    };
    let footer = LayoutRect {
        x: 0,
        y: body_viewport.height,
        width: client_width,
        height: footer_height,
    };
    let body_bounds = LayoutRect {
        x: 0,
        y: 0,
        width: client_width.saturating_sub(scale_dip(18, dpi)),
        height: body_content_height,
    };
    let content_width = body_bounds
        .width
        .saturating_sub(horizontal_margin.saturating_mul(2));
    let rect = |x, y, width, height| bounded_dialog_rect(x, y, width, height, body_bounds);
    let option_x = scale_dip(28, dpi);
    let option_width = body_bounds.width.saturating_sub(scale_dip(64, dpi));
    let group_option_y = |group_y: i32, index: i32| {
        group_y
            .saturating_add(scale_dip(22, dpi))
            .saturating_add(row_stride.saturating_mul(index))
    };
    let footer_button_width = if compact_footer {
        available_footer_width.saturating_sub(scale_dip(8, dpi)) / 2
    } else {
        button_width
    };
    let cancel_x = client_width
        .saturating_sub(horizontal_margin)
        .saturating_sub(footer_button_width);
    let ok_x = cancel_x
        .saturating_sub(scale_dip(8, dpi))
        .saturating_sub(footer_button_width);
    let buttons_y = if compact_footer {
        footer
            .y
            .saturating_add(scale_dip(10, dpi))
            .saturating_add(button_height)
            .saturating_add(scale_dip(6, dpi))
    } else {
        footer.y.saturating_add(scale_dip(9, dpi))
    };
    let reset_rect = if compact_footer {
        bounded_dialog_rect(
            horizontal_margin,
            footer.y.saturating_add(scale_dip(8, dpi)),
            available_footer_width,
            button_height,
            client,
        )
    } else {
        bounded_dialog_rect(
            horizontal_margin,
            buttons_y,
            reset_width,
            button_height,
            client,
        )
    };
    Some(AppearanceDialogLayout {
        client,
        body_viewport,
        body_content_height,
        scroll_max: body_content_height.saturating_sub(body_viewport.height),
        scroll_page: body_viewport.height,
        footer,
        compact_footer,
        density_group: rect(
            horizontal_margin,
            density_y,
            content_width,
            density_group_height,
        ),
        density_options: [
            rect(
                option_x,
                group_option_y(density_y, 0),
                option_width,
                row_height,
            ),
            rect(
                option_x,
                group_option_y(density_y, 1),
                option_width,
                row_height,
            ),
            rect(
                option_x,
                group_option_y(density_y, 2),
                option_width,
                row_height,
            ),
            rect(
                option_x,
                group_option_y(density_y, 3),
                option_width,
                row_height,
            ),
        ],
        emphasis_group: rect(
            horizontal_margin,
            emphasis_y,
            content_width,
            emphasis_group_height,
        ),
        emphasis_options: [
            rect(
                option_x,
                group_option_y(emphasis_y, 0),
                option_width,
                row_height,
            ),
            rect(
                option_x,
                group_option_y(emphasis_y, 1),
                option_width,
                row_height,
            ),
            rect(
                option_x,
                group_option_y(emphasis_y, 2),
                option_width,
                row_height,
            ),
        ],
        forced_explanation: if show_forced_explanation {
            rect(
                horizontal_margin,
                content_y,
                content_width,
                explanation_height,
            )
        } else {
            rect(horizontal_margin, content_y, 0, 0)
        },
        checkboxes: [
            rect(
                scale_dip(20, dpi),
                checkbox_y,
                body_bounds.width.saturating_sub(scale_dip(40, dpi)),
                checkbox_height,
            ),
            rect(
                scale_dip(20, dpi),
                checkbox_y.saturating_add(checkbox_stride),
                body_bounds.width.saturating_sub(scale_dip(40, dpi)),
                checkbox_height,
            ),
            rect(
                scale_dip(20, dpi),
                checkbox_y.saturating_add(checkbox_stride.saturating_mul(2)),
                body_bounds.width.saturating_sub(scale_dip(40, dpi)),
                checkbox_height,
            ),
        ],
        separator: rect(
            horizontal_margin,
            separator_y,
            content_width,
            scale_dip(1, dpi),
        ),
        reset: reset_rect,
        ok: bounded_dialog_rect(ok_x, buttons_y, footer_button_width, button_height, client),
        cancel: bounded_dialog_rect(
            cancel_x,
            buttons_y,
            footer_button_width,
            button_height,
            client,
        ),
    })
}

#[cfg(any(windows, test))]
#[must_use]
const fn horizontal_footer_minimum_width(dpi: u32, button_width: i32) -> i32 {
    scale_dip(24, dpi)
        .saturating_add(button_width.saturating_mul(2))
        .saturating_add(scale_dip(8, dpi))
}

/// Pixel metrics used to place one command rail.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UiMetrics {
    pub rail_top_padding: i32,
    pub rail_bottom_padding: i32,
    pub button_height: i32,
    pub group_gap: i32,
    pub rail_width: i32,
}

/// Native control and text extents used by the main-window layout.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct MeasuredFontMetrics {
    pub(crate) list_header_height: i32,
    pub(crate) button_text_width: i32,
    pub(crate) button_text_height: i32,
    pub(crate) status_text_height: i32,
    pub(crate) status_count_text_width: i32,
    pub(crate) cancel_text_width: i32,
    pub(crate) cancel_text_height: i32,
    pub(crate) empty_instruction_text_width: i32,
    pub(crate) empty_instruction_text_height: i32,
    pub(crate) empty_safety_text_width: i32,
    pub(crate) empty_safety_text_height: i32,
    pub(crate) empty_add_text_width: i32,
    pub(crate) empty_add_text_height: i32,
    pub(crate) empty_wrap_width: i32,
    pub(crate) empty_instruction_wrapped_height: i32,
    pub(crate) empty_safety_wrapped_height: i32,
    pub(crate) drop_overlay_text_width: i32,
    pub(crate) drop_overlay_text_height: i32,
}

/// Dynamic status-strip widths derived from the content currently displayed.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct StatusLayoutInput {
    pub(crate) cancel_visible: bool,
    pub(crate) measured_count_width: i32,
}

#[cfg(any(windows, test))]
impl MeasuredFontMetrics {
    #[must_use]
    pub(crate) fn rail_metrics(self, density: RailDensity, dpi: u32) -> UiMetrics {
        let mut metrics = density.metrics(dpi);
        let (horizontal_padding, vertical_padding) = match density {
            RailDensity::Comfortable => (12, 10),
            RailDensity::Compact => (10, 6),
        };
        metrics.rail_width = metrics.rail_width.max(
            self.button_text_width
                .max(0)
                .saturating_add(scale_dip(horizontal_padding, dpi)),
        );
        metrics.button_height = metrics.button_height.max(
            self.button_text_height
                .max(0)
                .saturating_add(scale_dip(vertical_padding, dpi)),
        );
        metrics
    }

    #[must_use]
    pub(crate) fn status_height(self, dpi: u32) -> i32 {
        scale_dip(STATUS_HEIGHT, dpi)
            .max(
                self.status_text_height
                    .max(0)
                    .saturating_add(scale_dip(4, dpi)),
            )
            .max(
                self.cancel_text_height
                    .max(0)
                    .saturating_add(scale_dip(6, dpi)),
            )
    }

    #[must_use]
    pub(crate) fn empty_state_minimum_width(self, dpi: u32) -> i32 {
        let text_padding = scale_dip(24, dpi);
        scale_dip(240, dpi)
            .max(
                self.empty_instruction_text_width
                    .max(0)
                    .saturating_add(text_padding),
            )
            .max(
                self.empty_add_text_width
                    .max(0)
                    .saturating_add(text_padding),
            )
    }

    pub(super) fn empty_state_content_metrics(
        self,
        dpi: u32,
        available_width: i32,
        show_safety: bool,
    ) -> EmptyStateContentMetrics {
        let available_width = available_width.max(0);
        let fallback_line_height = scale_dip(16, dpi);
        let instruction_height = if self.empty_wrap_width == available_width
            && self.empty_instruction_wrapped_height > 0
        {
            self.empty_instruction_wrapped_height
        } else {
            conservative_wrapped_text_height(
                self.empty_instruction_text_width.max(0),
                self.empty_instruction_text_height.max(fallback_line_height),
                available_width,
            )
        };
        let safety_height = if show_safety {
            if self.empty_wrap_width == available_width && self.empty_safety_wrapped_height > 0 {
                self.empty_safety_wrapped_height
            } else {
                conservative_wrapped_text_height(
                    self.empty_safety_text_width.max(0),
                    self.empty_safety_text_height.max(fallback_line_height),
                    available_width,
                )
            }
        } else {
            0
        };
        let add_width = self
            .empty_add_text_width
            .max(0)
            .saturating_add(scale_dip(24, dpi))
            .max(scale_dip(112, dpi))
            .min(available_width);
        let add_height = self
            .empty_add_text_height
            .max(fallback_line_height)
            .saturating_add(scale_dip(10, dpi))
            .max(scale_dip(28, dpi));
        let gap = scale_dip(8, dpi);
        EmptyStateContentMetrics {
            instruction_height,
            safety_height,
            add_width,
            add_height,
            total_height: instruction_height
                .saturating_add(gap)
                .saturating_add(add_height)
                .saturating_add(if show_safety {
                    gap.saturating_add(safety_height)
                } else {
                    0
                }),
        }
    }

    fn empty_state_required_height(self, dpi: u32, show_safety: bool) -> i32 {
        let content_width = self
            .empty_state_minimum_width(dpi)
            .saturating_sub(scale_dip(24, dpi));
        self.empty_state_content_metrics(dpi, content_width, show_safety)
            .total_height
            .saturating_add(scale_dip(24, dpi))
            .saturating_add(self.list_header_height.max(0))
    }
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct EmptyStateContentMetrics {
    pub(super) instruction_height: i32,
    pub(super) safety_height: i32,
    pub(super) add_width: i32,
    pub(super) add_height: i32,
    pub(super) total_height: i32,
}

#[cfg(any(windows, test))]
pub(super) fn conservative_wrapped_text_height(
    unwrapped_width: i32,
    line_height: i32,
    available_width: i32,
) -> i32 {
    let line_height = line_height.max(0);
    if available_width <= 0 {
        return 0;
    }
    let width = unwrapped_width.max(0);
    let mut lines = width
        .saturating_add(available_width - 1)
        .saturating_div(available_width)
        .max(1);
    if width > available_width {
        // Native SS_CENTER wrapping can leave unused space at word boundaries.
        // One conservative line prevents long localized safety copy clipping.
        lines = lines.saturating_add(1);
    }
    line_height.saturating_mul(lines)
}

impl RailDensity {
    /// Returns DPI-scaled pixel metrics for this density.
    #[must_use]
    pub const fn metrics(self, dpi: u32) -> UiMetrics {
        let (rail_bottom_padding, button_height, group_gap, rail_width) = match self {
            Self::Comfortable => (4, 32, 8, 52),
            Self::Compact => (2, 28, 4, 52),
        };
        UiMetrics {
            rail_top_padding: 0,
            rail_bottom_padding: scale_dip(rail_bottom_padding, dpi),
            button_height: scale_dip(button_height, dpi),
            group_gap: scale_dip(group_gap, dpi),
            rail_width: scale_dip(rail_width, dpi),
        }
    }
}

/// Calculated rectangle for one command button.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandPlacement {
    pub command: CommandId,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl CommandPlacement {
    /// Returns the exclusive bottom coordinate of this placement.
    #[must_use]
    pub fn bottom(self) -> i32 {
        self.y.saturating_add(self.height)
    }
}

/// Failure to calculate a bounded command-rail layout.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LayoutError {
    Overflow,
    InsufficientHeight { required: i32, available: i32 },
}

/// Selected command-rail presentation for the current client rectangle.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RailMode {
    Comfortable,
    Compact,
    MenuOnly,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn empty_state_safety_copy(mode: RailMode) -> &'static str {
    match mode {
        RailMode::Comfortable | RailMode::Compact => EMPTY_STATE_SAFETY_RAILS,
        RailMode::MenuOnly => EMPTY_STATE_SAFETY,
    }
}

/// Nonnegative child-window geometry calculated without Win32 dependencies.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct LayoutRect {
    pub(crate) x: i32,
    pub(crate) y: i32,
    pub(crate) width: i32,
    pub(crate) height: i32,
}

#[cfg(any(windows, test))]
impl LayoutRect {
    #[must_use]
    pub(crate) const fn right(self) -> i32 {
        self.x.saturating_add(self.width)
    }

    #[must_use]
    pub(crate) const fn bottom(self) -> i32 {
        self.y.saturating_add(self.height)
    }
}

/// Calculates the one-pixel menu-bottom repair in window-DC coordinates.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_menu_bottom_edge(
    window_screen: LayoutRect,
    menu_screen: LayoutRect,
) -> Option<LayoutRect> {
    if window_screen.width <= 0
        || window_screen.height <= 0
        || menu_screen.width <= 0
        || menu_screen.height <= 0
    {
        return None;
    }

    let window_right = window_screen.x.checked_add(window_screen.width)?;
    let window_bottom = window_screen.y.checked_add(window_screen.height)?;
    let menu_right = menu_screen.x.checked_add(menu_screen.width)?;
    let menu_bottom = menu_screen.y.checked_add(menu_screen.height)?;

    let left = menu_screen.x.max(window_screen.x);
    let right = menu_right.min(window_right);
    if right <= left || menu_bottom <= window_screen.y || menu_bottom >= window_bottom {
        return None;
    }

    Some(LayoutRect {
        x: left.checked_sub(window_screen.x)?,
        y: menu_bottom.checked_sub(window_screen.y)?,
        width: right.checked_sub(left)?,
        height: 1,
    })
}

/// App-owned status-strip geometry painted behind the inset native controls.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct StatusChromeGeometry {
    pub(crate) outer: LayoutRect,
    pub(crate) message_count_boundary: i32,
    pub(crate) top_line_right: i32,
}

/// App-owned one-pixel boundaries between visible rails and the ListView.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct WorkspaceChromeGeometry {
    pub(crate) left_list_divider: LayoutRect,
    pub(crate) right_list_divider: LayoutRect,
}

/// App-owned header geometry painted once after every item has been filled.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct HeaderChromeGeometry {
    pub(crate) gutter: LayoutRect,
    pub(crate) bottom_line: LayoutRect,
    pub(crate) item_dividers: Vec<LayoutRect>,
}

/// Complete main-client layout, including the explicit menu-only fallback.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct MainLayout {
    pub(crate) rail_mode: RailMode,
    pub(crate) rail_width: i32,
    pub(crate) left_buttons: Vec<CommandPlacement>,
    pub(crate) right_buttons: Vec<CommandPlacement>,
    pub(crate) workspace_chrome: WorkspaceChromeGeometry,
    pub(crate) list: LayoutRect,
    pub(crate) status_chrome: StatusChromeGeometry,
    pub(crate) status_message: LayoutRect,
    pub(crate) status_count: LayoutRect,
    pub(crate) cancel: LayoutRect,
    pub(crate) empty_instruction: LayoutRect,
    pub(crate) empty_safety: LayoutRect,
    pub(crate) empty_add: LayoutRect,
    pub(crate) drop_overlay: LayoutRect,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_header_chrome(
    client: LayoutRect,
    item_right_edges: &[i32],
) -> HeaderChromeGeometry {
    let line_height = i32::from(client.height > 0);
    let content_height = client.height.saturating_sub(line_height);
    let bottom_line = LayoutRect {
        x: client.x,
        y: client.bottom().saturating_sub(line_height),
        width: client.width,
        height: line_height,
    };
    let mut edges = item_right_edges.to_vec();
    edges.sort_unstable();
    edges.dedup();
    let last_item_right = edges
        .last()
        .copied()
        .unwrap_or(client.x)
        .clamp(client.x, client.right());
    let _ = edges.pop();
    let item_dividers = edges
        .into_iter()
        .filter(|edge| *edge > client.x && *edge <= client.right())
        .map(|edge| LayoutRect {
            x: edge.saturating_sub(1),
            y: client.y,
            width: 1,
            height: content_height,
        })
        .collect();
    HeaderChromeGeometry {
        gutter: LayoutRect {
            x: last_item_right,
            y: client.y,
            width: client.right().saturating_sub(last_item_right),
            height: content_height,
        },
        bottom_line,
        item_dividers,
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn main_layout_window_count(layout: &MainLayout) -> usize {
    layout
        .left_buttons
        .len()
        .saturating_add(layout.right_buttons.len())
        .saturating_add(command_rail_separator_count(&layout.left_buttons))
        .saturating_add(command_rail_separator_count(&layout.right_buttons))
        .saturating_add(usize::from(
            layout
                .left_buttons
                .iter()
                .chain(&layout.right_buttons)
                .any(|placement| placement.command == APPLY),
        ))
        .saturating_add(8)
}

#[cfg(any(windows, test))]
fn command_group(command: CommandId) -> Option<u8> {
    command_ui_spec(command).and_then(|spec| spec.rail.map(|placement| placement.group))
}

#[cfg(any(windows, test))]
fn command_rail_separator_count(placements: &[CommandPlacement]) -> usize {
    let mut count = 0_usize;
    let mut index = 1_usize;
    while index < placements.len() {
        if command_group(placements[index - 1].command) != command_group(placements[index].command)
        {
            count += 1;
        }
        index += 1;
    }
    count
}

/// Calculates centered, non-focusable separator rectangles inside group gaps.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_command_rail_separator_layout(
    placements: &[CommandPlacement],
    dpi: u32,
) -> Vec<LayoutRect> {
    let mut separators = Vec::with_capacity(command_rail_separator_count(placements));
    for pair in placements.windows(2) {
        if command_group(pair[0].command) == command_group(pair[1].command) {
            continue;
        }
        let gap_top = pair[0].bottom();
        let gap = pair[1].y.saturating_sub(gap_top).max(0);
        let height = scale_dip(2, dpi).max(1).min(gap);
        let left = pair[0].x.min(pair[1].x);
        let right = pair[0]
            .x
            .saturating_add(pair[0].width)
            .max(pair[1].x.saturating_add(pair[1].width));
        let rail_width = right.saturating_sub(left);
        let inset = scale_dip(6, dpi).max(0).min(rail_width.saturating_div(2));
        separators.push(LayoutRect {
            x: left.saturating_add(inset),
            y: gap_top.saturating_add(gap.saturating_sub(height) / 2),
            width: rail_width.saturating_sub(inset.saturating_mul(2)),
            height,
        });
    }
    separators
}

/// Painting geometry leaves layout spacing in DIP and hairlines in physical pixels.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ButtonPaintGeometry {
    pub(crate) outline: [LayoutRect; 4],
    pub(crate) default_outline: Option<LayoutRect>,
    pub(crate) focus: Option<LayoutRect>,
    pub(crate) pressed_offset: i32,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_button_paint_geometry(
    rect: LayoutRect,
    dpi: u32,
    shares_top_edge: bool,
) -> ButtonPaintGeometry {
    let width = rect.width.max(0);
    let height = rect.height.max(0);
    let inset = |amount: i32| {
        let inner_width = width.saturating_sub(amount.saturating_mul(2));
        let inner_height = height.saturating_sub(amount.saturating_mul(2));
        (inner_width > 0 && inner_height > 0).then_some(LayoutRect {
            x: rect.x.saturating_add(amount),
            y: rect.y.saturating_add(amount),
            width: inner_width,
            height: inner_height,
        })
    };
    ButtonPaintGeometry {
        outline: [
            LayoutRect {
                x: rect.x,
                y: rect.y,
                width,
                height: if shares_top_edge { 0 } else { height.min(1) },
            },
            LayoutRect {
                x: rect.x,
                y: rect.y,
                width: width.min(1),
                height,
            },
            LayoutRect {
                x: rect.x,
                y: rect.y.saturating_add(height.saturating_sub(1)),
                width,
                height: height.min(1),
            },
            LayoutRect {
                x: rect.x.saturating_add(width.saturating_sub(1)),
                y: rect.y,
                width: width.min(1),
                height,
            },
        ],
        default_outline: inset(1),
        focus: inset(scale_dip(3, dpi).max(0)),
        pressed_offset: scale_dip(1, dpi).max(0),
    }
}

/// Centers one physical hairline in the existing decorative separator slot.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn decorative_separator_line(slot: LayoutRect) -> LayoutRect {
    let height = slot.height.max(0);
    LayoutRect {
        x: slot.x,
        y: slot.y.saturating_add(height.saturating_sub(1) / 2),
        width: slot.width.max(0),
        height: height.min(1),
    }
}

/// Splits native scrollbar geometry without changing its hit-testing or range.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_scrollbar_parts(
    bar: LayoutRect,
    vertical: bool,
    arrow_length: i32,
    thumb_start: i32,
    thumb_end: i32,
) -> Option<[LayoutRect; 3]> {
    let length = if vertical { bar.height } else { bar.width };
    if bar.width <= 0
        || bar.height <= 0
        || arrow_length < 0
        || arrow_length > length / 2
        || thumb_start < arrow_length
        || thumb_end < thumb_start
        || thumb_end > length.saturating_sub(arrow_length)
    {
        return None;
    }
    let part = |start: i32, end: i32| {
        if vertical {
            LayoutRect {
                y: bar.y.saturating_add(start),
                height: end - start,
                ..bar
            }
        } else {
            LayoutRect {
                x: bar.x.saturating_add(start),
                width: end - start,
                ..bar
            }
        }
    };
    Some([
        part(0, arrow_length),
        part(thumb_start, thumb_end),
        part(length - arrow_length, length),
    ])
}

/// Restricts blank ListView body paint to client pixels below header and rows.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_blank_list_body_rect(
    client: LayoutRect,
    header_bottom: i32,
    last_row_bottom: i32,
) -> Option<LayoutRect> {
    let top = client
        .y
        .max(header_bottom)
        .max(last_row_bottom)
        .min(client.bottom());
    let height = client.bottom().saturating_sub(top);
    (client.width > 0 && height > 0).then_some(LayoutRect {
        x: client.x,
        y: top,
        width: client.width,
        height,
    })
}

/// Derives the decorative readiness indicator inside an Apply button.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_apply_readiness_indicator_rect(
    button: LayoutRect,
    dpi: u32,
) -> Option<LayoutRect> {
    let horizontal_inset = scale_dip(4, dpi).max(0).min(button.width.saturating_div(2));
    let available_width = button
        .width
        .saturating_sub(horizontal_inset.saturating_mul(2));
    let width = scale_dip(2, dpi).max(0).min(available_width);
    let vertical_inset = scale_dip(6, dpi)
        .max(0)
        .min(button.height.saturating_div(2));
    let height = button
        .height
        .saturating_sub(vertical_inset.saturating_mul(2));
    (width > 0 && height > 0).then_some(LayoutRect {
        x: button.x.saturating_add(horizontal_inset),
        y: button.y.saturating_add(vertical_inset),
        width,
        height,
    })
}

/// Message-font measurements used by the native prompt layout.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct PromptFontMetrics {
    pub(crate) title_width: i32,
    pub(crate) title_height: i32,
    pub(crate) label_width: i32,
    pub(crate) label_height: i32,
    pub(crate) line_height: i32,
}

/// Controls present in one prompt invocation.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct PromptFields {
    pub(crate) value_one: bool,
    pub(crate) value_two: bool,
    pub(crate) choice: bool,
}

/// Complete prompt client geometry calculated without Win32 dependencies.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PromptLayout {
    pub(crate) client: LayoutRect,
    pub(crate) title: LayoutRect,
    pub(crate) edit_one: Option<LayoutRect>,
    pub(crate) label_one: Option<LayoutRect>,
    pub(crate) edit_two: Option<LayoutRect>,
    pub(crate) label_two: Option<LayoutRect>,
    pub(crate) choice: Option<LayoutRect>,
    pub(crate) separator: LayoutRect,
    pub(crate) ok: LayoutRect,
    pub(crate) cancel: LayoutRect,
}

/// Calculates a message-font-aware prompt layout for the active field combination.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_prompt_layout(
    dpi: u32,
    measured: PromptFontMetrics,
    fields: PromptFields,
    maximum_client: LayoutRect,
) -> PromptLayout {
    let maximum_width = maximum_client.width.max(1);
    let maximum_height = maximum_client.height.max(1);
    let desired_padding = scale_dip(12, dpi);
    let desired_gap = scale_dip(8, dpi);
    let minimum_content_width = scale_dip(356, dpi);
    let desired_label_width = measured
        .label_width
        .max(0)
        .saturating_add(scale_dip(8, dpi))
        .max(scale_dip(70, dpi));
    let desired_edit_width = scale_dip(275, dpi);
    let desired_field_width = desired_edit_width
        .saturating_add(desired_gap)
        .saturating_add(desired_label_width);
    let desired_content_width = minimum_content_width
        .max(measured.title_width.max(0))
        .max(desired_field_width);
    let client_width = desired_content_width
        .saturating_add(desired_padding.saturating_mul(2))
        .min(maximum_width)
        .max(1);
    let horizontal_padding = desired_padding.min(client_width.saturating_sub(1) / 2);
    let content_width = client_width
        .saturating_sub(horizontal_padding.saturating_mul(2))
        .max(1);
    let horizontal_gap = desired_gap.min(content_width.saturating_sub(2) / 4);
    let field_space = content_width.saturating_sub(horizontal_gap);
    let label_width = desired_label_width
        .min((field_space / 3).max(1))
        .min(field_space);
    let edit_width = field_space.saturating_sub(label_width);
    let line_height = measured.line_height.max(scale_dip(16, dpi));
    let desired_title_height = measured.title_height.max(line_height);
    let desired_field_height = line_height
        .saturating_add(scale_dip(8, dpi))
        .max(measured.label_height.max(0));
    let desired_button_height = line_height.saturating_add(scale_dip(14, dpi));
    let desired_separator_height = scale_dip(2, dpi).max(1);
    let section_count = 3_usize
        .saturating_add(usize::from(fields.value_one))
        .saturating_add(usize::from(fields.value_two))
        .saturating_add(usize::from(fields.choice));
    let gap_count = section_count.saturating_sub(1);
    let mut desired_heights = Vec::with_capacity(section_count);
    desired_heights.push(desired_title_height);
    if fields.value_one {
        desired_heights.push(desired_field_height);
    }
    if fields.value_two {
        desired_heights.push(desired_field_height);
    }
    if fields.choice {
        desired_heights.push(desired_field_height);
    }
    desired_heights.push(desired_separator_height);
    desired_heights.push(desired_button_height);
    let desired_sections_height = desired_heights
        .iter()
        .fold(0_i32, |total, height| total.saturating_add(*height));
    let desired_client_height = desired_sections_height
        .saturating_add(desired_gap.saturating_mul(i32::try_from(gap_count).unwrap_or(i32::MAX)))
        .saturating_add(desired_padding.saturating_mul(2));
    let client_height = desired_client_height.min(maximum_height).max(1);
    let minimum_sections_height = i32::try_from(section_count).unwrap_or(i32::MAX);
    let vertical_padding =
        desired_padding.min(client_height.saturating_sub(minimum_sections_height).max(0) / 2);
    let available_after_padding = client_height
        .saturating_sub(vertical_padding.saturating_mul(2))
        .max(0);
    let vertical_gap = if gap_count == 0 {
        0
    } else {
        desired_gap.min(
            available_after_padding
                .saturating_sub(minimum_sections_height)
                .max(0)
                / i32::try_from(gap_count).unwrap_or(i32::MAX),
        )
    };
    let available_for_sections = available_after_padding
        .saturating_sub(vertical_gap.saturating_mul(i32::try_from(gap_count).unwrap_or(i32::MAX)));
    let heights = fit_prompt_section_heights(&desired_heights, available_for_sections);
    let mut height_index = 0_usize;
    let mut next_height = || {
        let height = heights.get(height_index).copied().unwrap_or_default();
        height_index = height_index.saturating_add(1);
        height
    };

    let title = LayoutRect {
        x: horizontal_padding,
        y: vertical_padding,
        width: content_width,
        height: next_height(),
    };
    let mut y = title.bottom().saturating_add(vertical_gap);
    let mut field = |present: bool| {
        present.then(|| {
            let height = next_height();
            let label = LayoutRect {
                x: horizontal_padding,
                y,
                width: label_width,
                height,
            };
            let edit = LayoutRect {
                x: horizontal_padding
                    .saturating_add(label_width)
                    .saturating_add(horizontal_gap),
                y,
                width: edit_width,
                height,
            };
            y = y.saturating_add(height).saturating_add(vertical_gap);
            (edit, label)
        })
    };
    let (edit_one, label_one) = field(fields.value_one).unzip();
    let (edit_two, label_two) = field(fields.value_two).unzip();
    let choice = fields.choice.then(|| {
        let height = next_height();
        let rect = LayoutRect {
            x: horizontal_padding,
            y,
            width: scale_dip(185, dpi).min(content_width),
            height,
        };
        y = y.saturating_add(height).saturating_add(vertical_gap);
        rect
    });
    let separator = LayoutRect {
        x: 0,
        y,
        width: client_width,
        height: next_height(),
    };
    let button_y = separator.bottom().saturating_add(vertical_gap);
    let button_height = next_height();
    let button_gap = horizontal_gap.min(content_width.saturating_sub(2) / 3);
    let available_for_buttons = content_width.saturating_sub(button_gap);
    let button_width = scale_dip(75, dpi).min(available_for_buttons / 2);
    let cancel = LayoutRect {
        x: client_width
            .saturating_sub(horizontal_padding)
            .saturating_sub(button_width),
        y: button_y,
        width: button_width,
        height: button_height,
    };
    let ok = LayoutRect {
        x: cancel
            .x
            .saturating_sub(button_gap)
            .saturating_sub(button_width),
        y: button_y,
        width: button_width,
        height: button_height,
    };
    PromptLayout {
        client: LayoutRect {
            x: 0,
            y: 0,
            width: client_width,
            height: client_height,
        },
        title,
        edit_one,
        label_one,
        edit_two,
        label_two,
        choice,
        separator,
        ok,
        cancel,
    }
}

#[cfg(any(windows, test))]
fn fit_prompt_section_heights(desired: &[i32], available: i32) -> Vec<i32> {
    let available = available.max(0);
    let desired_total = desired
        .iter()
        .fold(0_i32, |total, height| total.saturating_add(*height));
    if desired_total <= available {
        return desired.to_vec();
    }
    let mut heights = vec![0; desired.len()];
    let mut remaining = available;
    for height in &mut heights {
        if remaining == 0 {
            break;
        }
        *height = 1;
        remaining -= 1;
    }
    while remaining > 0 {
        let mut progressed = false;
        for (height, target) in heights.iter_mut().zip(desired) {
            if remaining == 0 {
                break;
            }
            if *height < *target {
                *height += 1;
                remaining -= 1;
                progressed = true;
            }
        }
        if !progressed {
            break;
        }
    }
    heights
}

pub(super) fn required_command_rail_height(
    spec: &CommandRailSpec,
    metrics: UiMetrics,
) -> Result<i32, LayoutError> {
    let command_count = i32::try_from(spec.command_count()).map_err(|_| LayoutError::Overflow)?;
    let group_gaps =
        i32::try_from(spec.group_count().saturating_sub(1)).map_err(|_| LayoutError::Overflow)?;
    metrics
        .rail_top_padding
        .checked_add(metrics.rail_bottom_padding)
        .and_then(|padding| {
            metrics
                .button_height
                .checked_mul(command_count)
                .and_then(|buttons| padding.checked_add(buttons))
        })
        .and_then(|height| {
            metrics
                .group_gap
                .checked_mul(group_gaps)
                .and_then(|gaps| height.checked_add(gaps))
        })
        .ok_or(LayoutError::Overflow)
}

/// Calculates one non-overlapping vertical column of command buttons.
pub fn calculate_command_rail_layout(
    spec: &CommandRailSpec,
    available_height: i32,
    metrics: UiMetrics,
) -> Result<Vec<CommandPlacement>, LayoutError> {
    let required = required_command_rail_height(spec, metrics)?;
    if required > available_height {
        return Err(LayoutError::InsufficientHeight {
            required,
            available: available_height,
        });
    }

    let mut placements = Vec::with_capacity(spec.command_count());
    let mut y = metrics.rail_top_padding;
    let mut previous_group = None;
    for command_spec in spec.command_specs() {
        let group = command_spec
            .rail
            .map(|placement| placement.group)
            .ok_or(LayoutError::Overflow)?;
        if previous_group.is_some_and(|previous| previous != group) {
            y = y
                .checked_add(metrics.group_gap)
                .ok_or(LayoutError::Overflow)?;
        }
        previous_group = Some(group);
        placements.push(CommandPlacement {
            command: command_spec.id,
            x: 0,
            y,
            width: metrics.rail_width,
            height: metrics.button_height,
        });
        y = y
            .checked_add(metrics.button_height)
            .ok_or(LayoutError::Overflow)?;
    }
    Ok(placements)
}

/// Selects the most spacious density that fits both command rails.
pub fn select_command_rail_density(
    available_height: i32,
    dpi: u32,
) -> Result<RailDensity, LayoutError> {
    select_command_rail_density_with_preference(
        available_height,
        dpi,
        RailDensityPreference::Automatic,
    )
}

/// Selects the preferred density without substituting another explicit choice.
pub fn select_command_rail_density_with_preference(
    available_height: i32,
    dpi: u32,
    preference: RailDensityPreference,
) -> Result<RailDensity, LayoutError> {
    for density in preference.candidates().iter().copied() {
        let metrics = density.metrics(dpi);
        if required_command_rail_height(&LEFT_RAIL, metrics)? <= available_height
            && required_command_rail_height(&RIGHT_RAIL, metrics)? <= available_height
        {
            return Ok(density);
        }
    }
    let required = preference.minimum_density().map_or(Ok(0), |density| {
        required_command_rail_height(&LEFT_RAIL, density.metrics(dpi))
    })?;
    Err(LayoutError::InsufficientHeight {
        required,
        available: available_height,
    })
}

#[cfg(test)]
#[must_use]
pub(crate) fn minimum_main_client_height(
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
) -> i32 {
    minimum_main_client_height_with_safety(dpi, measured, preference, true)
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn minimum_main_client_height_with_safety(
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
    show_empty_safety: bool,
) -> i32 {
    let rail_height = preference.minimum_density().map_or(0, |density| {
        let metrics = measured.rail_metrics(density, dpi);
        let left = required_command_rail_height(&LEFT_RAIL, metrics).unwrap_or(i32::MAX);
        let right = required_command_rail_height(&RIGHT_RAIL, metrics).unwrap_or(i32::MAX);
        left.max(right)
    });
    rail_height
        .max(measured.empty_state_required_height(dpi, show_empty_safety))
        .saturating_add(measured.status_height(dpi))
}

#[cfg(test)]
#[must_use]
pub(crate) fn recommended_main_client_height(
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
) -> i32 {
    recommended_main_client_height_with_safety(dpi, measured, preference, true)
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn recommended_main_client_height_with_safety(
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
    show_empty_safety: bool,
) -> i32 {
    let rail_height = preference.recommended_density().map_or(0, |density| {
        let metrics = measured.rail_metrics(density, dpi);
        let left = required_command_rail_height(&LEFT_RAIL, metrics).unwrap_or(i32::MAX);
        let right = required_command_rail_height(&RIGHT_RAIL, metrics).unwrap_or(i32::MAX);
        left.max(right)
    });
    rail_height
        .max(measured.empty_state_required_height(dpi, show_empty_safety))
        .saturating_add(measured.status_height(dpi))
}

#[cfg(test)]
#[must_use]
pub(crate) fn calculate_main_layout(
    client_width: i32,
    client_height: i32,
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
) -> MainLayout {
    calculate_main_layout_with_safety(
        client_width,
        client_height,
        dpi,
        measured,
        preference,
        true,
        StatusLayoutInput {
            cancel_visible: false,
            measured_count_width: measured.status_count_text_width,
        },
    )
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_main_layout_with_safety(
    client_width: i32,
    client_height: i32,
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
    show_empty_safety: bool,
    status: StatusLayoutInput,
) -> MainLayout {
    let width = client_width.max(0);
    let height = client_height.max(0);
    let status_height = measured.status_height(dpi).min(height);
    let rail_height = height.saturating_sub(status_height);

    let selected = preference.candidates().iter().copied().find_map(|density| {
        let metrics = measured.rail_metrics(density, dpi);
        let rails_width = metrics.rail_width.saturating_mul(2);
        if rails_width.saturating_add(2) >= width {
            return None;
        }
        let left = calculate_command_rail_layout(&LEFT_RAIL, rail_height, metrics).ok()?;
        let right = calculate_command_rail_layout(&RIGHT_RAIL, rail_height, metrics).ok()?;
        Some((density, metrics.rail_width, left, right))
    });

    let (rail_mode, rail_width, left_buttons, right_buttons) = match selected {
        Some((RailDensity::Comfortable, rail_width, left, right)) => {
            (RailMode::Comfortable, rail_width, left, right)
        }
        Some((RailDensity::Compact, rail_width, left, right)) => {
            (RailMode::Compact, rail_width, left, right)
        }
        None => (RailMode::MenuOnly, 0, Vec::new(), Vec::new()),
    };
    let (workspace_chrome, list) = if rail_width > 0 {
        let left_list_divider = LayoutRect {
            x: rail_width,
            y: 0,
            width: 1,
            height: rail_height,
        };
        let right_list_divider = LayoutRect {
            x: width.saturating_sub(rail_width).saturating_sub(1),
            y: 0,
            width: 1,
            height: rail_height,
        };
        (
            WorkspaceChromeGeometry {
                left_list_divider,
                right_list_divider,
            },
            LayoutRect {
                x: rail_width.saturating_add(1),
                y: 0,
                width: width
                    .saturating_sub(rail_width.saturating_mul(2))
                    .saturating_sub(2),
                height: rail_height,
            },
        )
    } else {
        (
            WorkspaceChromeGeometry::default(),
            LayoutRect {
                x: 0,
                y: 0,
                width,
                height: rail_height,
            },
        )
    };
    let cancel_preferred = if status.cancel_visible {
        measured
            .cancel_text_width
            .max(scale_dip(36, dpi))
            .saturating_add(scale_dip(16, dpi))
    } else {
        0
    };
    let cancel_width = cancel_preferred.min(width);
    let after_cancel = width.saturating_sub(cancel_width);
    let count_preferred = status
        .measured_count_width
        .max(scale_dip(44, dpi))
        .saturating_add(scale_dip(16, dpi));
    let count_width = count_preferred.min(after_cancel);
    let message_width = after_cancel.saturating_sub(count_width);
    let status_outer = LayoutRect {
        x: 0,
        y: rail_height,
        width,
        height: status_height,
    };
    let message_count_boundary = message_width;
    let top_line_right = message_width.saturating_add(count_width);
    let inset_status_text = |rect: LayoutRect| {
        let horizontal_inset = scale_dip(8, dpi).min(rect.width.saturating_div(2));
        let top_line_height = i32::from(rect.height > 0);
        LayoutRect {
            x: rect.x.saturating_add(horizontal_inset),
            y: rect.y.saturating_add(top_line_height),
            width: rect
                .width
                .saturating_sub(horizontal_inset.saturating_mul(2)),
            height: rect.height.saturating_sub(top_line_height),
        }
    };
    let status_message = inset_status_text(LayoutRect {
        x: 0,
        y: rail_height,
        width: message_width,
        height: status_height,
    });
    let status_count = inset_status_text(LayoutRect {
        x: message_width,
        y: rail_height,
        width: count_width,
        height: status_height,
    });
    let empty = calculate_empty_state_layout(list, dpi, measured, show_empty_safety);
    let drop_overlay = calculate_drop_overlay_layout(list, dpi, measured);
    MainLayout {
        rail_mode,
        rail_width,
        left_buttons,
        right_buttons,
        workspace_chrome,
        list,
        status_chrome: StatusChromeGeometry {
            outer: status_outer,
            message_count_boundary,
            top_line_right,
        },
        status_message,
        status_count,
        cancel: LayoutRect {
            x: message_width.saturating_add(count_width),
            y: rail_height,
            width: cancel_width,
            height: status_height,
        },
        empty_instruction: empty.instruction,
        empty_safety: empty.safety,
        empty_add: empty.add,
        drop_overlay,
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(super) fn calculate_drop_overlay_layout(
    list: LayoutRect,
    dpi: u32,
    measured: MeasuredFontMetrics,
) -> LayoutRect {
    let horizontal_padding = scale_dip(12, dpi).min(list.width.saturating_div(2));
    let width = list
        .width
        .saturating_sub(horizontal_padding.saturating_mul(2));
    let line_height = measured.drop_overlay_text_height.max(scale_dip(16, dpi));
    let desired_height =
        conservative_wrapped_text_height(measured.drop_overlay_text_width, line_height, width)
            .saturating_add(scale_dip(10, dpi))
            .max(scale_dip(28, dpi));
    let height = desired_height.min(list.height).max(0);
    LayoutRect {
        x: list.x.saturating_add(horizontal_padding),
        y: list
            .y
            .saturating_add(list.height.saturating_sub(height) / 2),
        width,
        height,
    }
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct EmptyStateLayout {
    pub(super) instruction: LayoutRect,
    safety: LayoutRect,
    pub(super) add: LayoutRect,
}

#[cfg(any(windows, test))]
#[must_use]
pub(super) fn calculate_empty_state_layout(
    list: LayoutRect,
    dpi: u32,
    measured: MeasuredFontMetrics,
    show_safety: bool,
) -> EmptyStateLayout {
    let header_height = measured.list_header_height.max(0).min(list.height);
    let data = LayoutRect {
        x: list.x,
        y: list.y.saturating_add(header_height),
        width: list.width,
        height: list.height.saturating_sub(header_height),
    };
    let horizontal_padding = scale_dip(12, dpi).min(data.width.saturating_div(2));
    let content_width = data
        .width
        .saturating_sub(horizontal_padding.saturating_mul(2));
    let content = measured.empty_state_content_metrics(dpi, content_width, show_safety);
    let desired_instruction_height = content.instruction_height;
    let desired_button_height = content.add_height;
    let desired_safety_height = content.safety_height;
    let desired_gap = scale_dip(8, dpi);
    let desired_total = content.total_height;
    let top = data
        .y
        .saturating_add(data.height.saturating_sub(desired_total).max(0) / 2);
    let bottom = data.bottom();
    let mut y = top;
    let instruction_y = y;
    let instruction_height = desired_instruction_height
        .min(bottom.saturating_sub(y))
        .max(0);
    y = y.saturating_add(instruction_height);
    y = y.saturating_add(desired_gap.min(bottom.saturating_sub(y)).max(0));
    let button_y = y;
    let button_height = desired_button_height.min(bottom.saturating_sub(y)).max(0);
    y = y.saturating_add(button_height);
    if show_safety {
        y = y.saturating_add(desired_gap.min(bottom.saturating_sub(y)).max(0));
    }
    let safety_y = y;
    let safety_height = desired_safety_height.min(bottom.saturating_sub(y)).max(0);
    let button_width = content.add_width;
    EmptyStateLayout {
        instruction: LayoutRect {
            x: data.x.saturating_add(horizontal_padding),
            y: instruction_y,
            width: content_width,
            height: instruction_height,
        },
        safety: LayoutRect {
            x: data.x.saturating_add(horizontal_padding),
            y: safety_y,
            width: content_width,
            height: safety_height,
        },
        add: LayoutRect {
            x: data
                .x
                .saturating_add(data.width.saturating_sub(button_width) / 2),
            y: button_y,
            width: button_width,
            height: button_height,
        },
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn adaptive_primary_column_widths(available: i32, dpi: u32) -> [i32; 3] {
    let available = available.max(0);
    let minimum = [
        scale_dip(NAME_COLUMN_MINIMUM, dpi),
        scale_dip(NAME_COLUMN_MINIMUM, dpi),
        scale_dip(LOCATION_COLUMN_MINIMUM, dpi),
    ];
    let minimum_total = minimum.iter().copied().map(i64::from).sum::<i64>();
    if i64::from(available) < minimum_total {
        let location = minimum[2].min(available);
        let names_available = available - location;
        let current = (names_available + 1) / 2;
        return [current, names_available - current, location];
    }

    // Current and proposed names are the primary comparison surface. Give each
    // two shares of surplus while retaining one share for location context.
    let remaining = i32::try_from(i64::from(available) - minimum_total).unwrap_or_default();
    let each_share = remaining / 5;
    let mut widths = [
        minimum[0] + each_share * 2,
        minimum[1] + each_share * 2,
        minimum[2] + each_share,
    ];
    for index in [0, 1, 2, 0, 1]
        .into_iter()
        .take(usize::try_from(remaining % 5).unwrap_or(0))
    {
        widths[index] += 1;
    }
    widths
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ColumnState {
    pub(crate) visible: bool,
    pub(crate) width_dip: i32,
    pub(crate) user_resized: bool,
}

#[cfg(any(windows, test))]
impl ColumnState {
    pub(crate) const fn visible(width_dip: i32) -> Self {
        Self {
            visible: true,
            width_dip,
            user_resized: false,
        }
    }

    pub(crate) const fn hidden(width_dip: i32) -> Self {
        Self {
            visible: false,
            width_dip,
            user_resized: false,
        }
    }

    pub(crate) fn set_visible(&mut self, visible: bool) {
        self.visible = visible;
    }

    pub(crate) fn record_user_resize(&mut self, width_px: i32, dpi: u32) {
        self.width_dip = unscale_px(width_px.max(0), dpi);
        self.user_resized = true;
    }

    pub(crate) const fn width_px(self, dpi: u32) -> i32 {
        scale_dip(self.width_dip, dpi)
    }
}

#[cfg(any(windows, test))]
pub(crate) const fn default_column_states() -> [ColumnState; 7] {
    [
        ColumnState::visible(150),
        ColumnState::visible(150),
        ColumnState::visible(100),
        ColumnState::hidden(120),
        ColumnState::hidden(80),
        ColumnState::hidden(120),
        ColumnState::hidden(120),
    ]
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn status_column_width_after_resize(
    requested_width_px: i32,
    measured_minimum_px: i32,
    dpi: u32,
) -> i32 {
    unscale_px(requested_width_px.max(measured_minimum_px), dpi).max(NATIVE_STATUS_COLUMN_WIDTH_DIP)
}

#[cfg(any(windows, test))]
const fn unscale_px(value: i32, dpi: u32) -> i32 {
    if dpi == 0 {
        return value;
    }
    let product = (value as i128) * (BASE_DPI as i128);
    let scaled = (product + (dpi / 2) as i128) / (dpi as i128);
    if scaled > i32::MAX as i128 {
        i32::MAX
    } else {
        scaled as i32
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn allocate_primary_column_widths(
    client_width: i32,
    status_width: i32,
    dpi: u32,
    columns: &[ColumnState; 7],
) -> [i32; 3] {
    let automatic_default_layout = columns[..3].iter().all(|column| !column.user_resized)
        && columns[3..].iter().all(|column| !column.visible);
    let optional_width = columns[3..]
        .iter()
        .filter(|column| column.visible)
        .map(|column| column.width_px(dpi))
        .fold(0_i32, i32::saturating_add);
    let budget = client_width
        .max(0)
        .saturating_sub(status_width.max(0))
        .saturating_sub(optional_width)
        .saturating_sub(if automatic_default_layout {
            scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi).max(1)
        } else {
            0
        });
    let minimum = [
        scale_dip(NAME_COLUMN_MINIMUM, dpi),
        scale_dip(NAME_COLUMN_MINIMUM, dpi),
        scale_dip(LOCATION_COLUMN_MINIMUM, dpi),
    ];
    if columns[..3].iter().all(|column| !column.user_resized) && budget >= minimum.iter().sum() {
        return adaptive_primary_column_widths(budget, dpi);
    }
    let preferred = [
        scale_dip(COLUMNS[0].default_width, dpi),
        scale_dip(COLUMNS[1].default_width, dpi),
        scale_dip(COLUMNS[2].default_width, dpi),
    ];
    let mut widths = [0; 3];
    let mut automatic = [false; 3];
    let mut required = 0_i32;
    for index in 0..3 {
        if columns[index].user_resized {
            widths[index] = columns[index].width_px(dpi);
        } else {
            widths[index] = minimum[index];
            automatic[index] = true;
        }
        required = required.saturating_add(widths[index]);
    }
    let mut remaining = budget.saturating_sub(required);

    let automatic_names = usize::from(automatic[0]) + usize::from(automatic[1]);
    if automatic_names != 0 && remaining > 0 {
        let name_deficit = (0..2)
            .filter(|index| automatic[*index])
            .map(|index| preferred[index].saturating_sub(widths[index]))
            .sum::<i32>();
        let distributed = remaining.min(name_deficit);
        let each = distributed / i32::try_from(automatic_names).unwrap_or(1);
        let mut remainder = distributed % i32::try_from(automatic_names).unwrap_or(1);
        for index in 0..2 {
            if automatic[index] {
                let extra = each + i32::from(remainder > 0);
                widths[index] = widths[index].saturating_add(extra);
                remainder = remainder.saturating_sub(1);
            }
        }
        remaining -= distributed;
    }
    if automatic[2] && remaining > 0 {
        let distributed = remaining.min(preferred[2].saturating_sub(widths[2]));
        widths[2] = widths[2].saturating_add(distributed);
        remaining -= distributed;
    }
    if remaining > 0
        && let Some(index) = automatic.iter().rposition(|automatic| *automatic)
    {
        widths[index] = widths[index].saturating_add(remaining);
    }
    widths
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn minimum_content_width_px(dpi: u32, status_width_px: i32) -> i32 {
    RailDensity::Comfortable
        .metrics(dpi)
        .rail_width
        .saturating_mul(2)
        .saturating_add(scale_dip(NAME_COLUMN_MINIMUM, dpi).saturating_mul(2))
        .saturating_add(scale_dip(LOCATION_COLUMN_MINIMUM, dpi))
        .saturating_add(scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi).max(1))
        .saturating_add(status_width_px.max(0))
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn minimum_main_client_width(
    dpi: u32,
    measured: MeasuredFontMetrics,
    preference: RailDensityPreference,
    status_width_px: i32,
) -> i32 {
    let rail_width = preference
        .candidates()
        .iter()
        .copied()
        .map(|density| measured.rail_metrics(density, dpi).rail_width)
        .max()
        .unwrap_or(0);
    let baseline_rail_width = preference
        .minimum_density()
        .map_or(0, |density| density.metrics(dpi).rail_width);
    let workspace_divider_width = i32::from(rail_width > 0).saturating_mul(2);
    minimum_content_width_px(dpi, status_width_px)
        .saturating_add(
            rail_width
                .saturating_sub(baseline_rail_width)
                .saturating_mul(2),
        )
        .saturating_add(workspace_divider_width)
        .max(
            rail_width
                .saturating_mul(2)
                .saturating_add(measured.empty_state_minimum_width(dpi))
                .saturating_add(workspace_divider_width),
        )
}

/// One report-mode ListView column.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ColumnSpec {
    pub label: &'static str,
    pub default_width: i32,
}

pub const COLUMNS: [ColumnSpec; 7] = [
    ColumnSpec {
        label: "현재 이름",
        default_width: 150,
    },
    ColumnSpec {
        label: "변경 후 이름",
        default_width: 150,
    },
    ColumnSpec {
        label: "대상 폴더",
        default_width: 100,
    },
    ColumnSpec {
        label: "현재 전체 경로",
        default_width: 0,
    },
    ColumnSpec {
        label: "파일 크기",
        default_width: 0,
    },
    ColumnSpec {
        label: "수정 시각",
        default_width: 0,
    },
    ColumnSpec {
        label: "생성 시각",
        default_width: 0,
    },
];

/// Fixed native-only column. It is deliberately absent from `COLUMNS` and
/// the seven-column `ui-columns-v1` persistence contract.
#[cfg(any(windows, test))]
pub(crate) const NATIVE_STATUS_COLUMN: ColumnSpec = ColumnSpec {
    label: "상태",
    default_width: NATIVE_STATUS_COLUMN_WIDTH_DIP,
};
/// Report-mode index of the fixed native-only Status column.
#[cfg(any(windows, test))]
pub(crate) const NATIVE_STATUS_COLUMN_INDEX: usize = COLUMNS.len();
/// Total columns rendered by the native report ListView.
#[cfg(any(windows, test))]
pub(crate) const NATIVE_LIST_COLUMN_COUNT: usize = COLUMNS.len() + 1;
