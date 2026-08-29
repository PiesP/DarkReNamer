//! Native Win32 shell and stable DarkNamer 08.02.10 UI contract.

#![cfg_attr(not(windows), forbid(unsafe_code))]

/// Bounded filesystem admission for native picker, drop, and path import.
pub mod admission;
/// Bounded shell-icon cache key derivation.
pub mod icon_cache;
/// Safe rename planning and execution foundation.
pub mod rename;

/// Original outer window width used by the parity shell.
pub const INITIAL_WIDTH: i32 = 464;
/// Original outer window height used by the parity shell.
pub const INITIAL_HEIGHT: i32 = 408;
/// Height of the bottom status bar.
pub const STATUS_HEIGHT: i32 = 18;
/// Design coordinate density used by the original Win32 layout.
pub const BASE_DPI: u32 = 96;
#[cfg(any(windows, test))]
pub(crate) const NAME_COLUMN_MINIMUM: i32 = 120;
#[cfg(any(windows, test))]
pub(crate) const LOCATION_COLUMN_MINIMUM: i32 = 80;
#[cfg(any(windows, test))]
pub(crate) const LIST_SCROLLBAR_ALLOWANCE_DIP: i32 = 17;
#[cfg(any(windows, test))]
pub(crate) const EMPTY_LIST_STATUS: &str = "파일이나 폴더를 끌어 놓거나 Ctrl+O로 추가하세요.";

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HorizontalWindowPlacement {
    pub(crate) x: i32,
    pub(crate) width: i32,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn fit_widened_window_to_work_area(
    current_x: i32,
    work_left: i32,
    work_right: i32,
    minimum_width: i32,
) -> Option<HorizontalWindowPlacement> {
    let work_width = work_right.checked_sub(work_left)?;
    if work_width <= 0 || minimum_width <= 0 {
        return None;
    }
    let width = minimum_width.min(work_width);
    let latest_x = work_right - width;
    Some(HorizontalWindowPlacement {
        x: current_x.clamp(work_left, latest_x),
        width,
    })
}

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

/// Side of the main window occupied by a visible command rail.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RailSide {
    Left,
    Right,
}

/// Ordered command groups for one side of the main window.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandRailSpec {
    pub side: RailSide,
}

impl CommandRailSpec {
    /// Returns the total number of visible commands in this rail.
    #[must_use]
    pub fn command_count(self) -> usize {
        self.command_specs().count()
    }

    /// Iterates over visible command identifiers in display order.
    pub fn commands(self) -> impl Iterator<Item = CommandId> {
        self.command_specs().map(|spec| spec.id)
    }

    /// Iterates over the catalog entries visible on this rail.
    pub fn command_specs(self) -> impl Iterator<Item = &'static CommandUiSpec> {
        COMMAND_UI_SPECS.iter().filter(move |spec| {
            spec.rail
                .is_some_and(|placement| placement.side == self.side)
        })
    }

    fn group_count(self) -> usize {
        self.command_specs()
            .fold((None, 0), |(previous, count), spec| {
                let group = spec.rail.map(|placement| placement.group);
                (group, count + usize::from(group != previous))
            })
            .1
    }
}

/// Supported command-rail density.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RailDensity {
    Comfortable,
    Compact,
}

/// Pixel metrics used to place one command rail.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UiMetrics {
    pub rail_padding: i32,
    pub button_height: i32,
    pub group_gap: i32,
    pub rail_width: i32,
}

/// Text extents measured from the active native message and status fonts.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct MeasuredFontMetrics {
    pub(crate) button_text_width: i32,
    pub(crate) button_text_height: i32,
    pub(crate) status_text_height: i32,
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
        scale_dip(STATUS_HEIGHT, dpi).max(
            self.status_text_height
                .max(0)
                .saturating_add(scale_dip(4, dpi)),
        )
    }
}

impl RailDensity {
    /// Returns DPI-scaled pixel metrics for this density.
    #[must_use]
    pub const fn metrics(self, dpi: u32) -> UiMetrics {
        let (rail_padding, button_height, group_gap, rail_width) = match self {
            Self::Comfortable => (4, 32, 8, 52),
            Self::Compact => (2, 28, 4, 52),
        };
        UiMetrics {
            rail_padding: scale_dip(rail_padding, dpi),
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
    pub(crate) const fn bottom(self) -> i32 {
        self.y.saturating_add(self.height)
    }
}

/// Complete main-client layout, including the explicit menu-only fallback.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct MainLayout {
    pub(crate) rail_mode: RailMode,
    pub(crate) rail_width: i32,
    pub(crate) left_buttons: Vec<CommandPlacement>,
    pub(crate) right_buttons: Vec<CommandPlacement>,
    pub(crate) list: LayoutRect,
    pub(crate) status: LayoutRect,
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

/// Directory admission selected by the three-way native prompt.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DirectoryPromptChoice {
    Direct,
    Recurse,
    Cancel,
}

/// Maps native YES/NO/CANCEL response values, failing closed for every unknown result.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn directory_prompt_choice(result: i32) -> DirectoryPromptChoice {
    match result {
        6 => DirectoryPromptChoice::Direct,
        7 => DirectoryPromptChoice::Recurse,
        _ => DirectoryPromptChoice::Cancel,
    }
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
            let edit = LayoutRect {
                x: horizontal_padding,
                y,
                width: edit_width,
                height,
            };
            let label = LayoutRect {
                x: horizontal_padding
                    .saturating_add(edit_width)
                    .saturating_add(horizontal_gap),
                y,
                width: label_width,
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

/// Explicit left-side command grouping.
pub const LEFT_RAIL: CommandRailSpec = CommandRailSpec {
    side: RailSide::Left,
};
/// Explicit right-side command grouping.
pub const RIGHT_RAIL: CommandRailSpec = CommandRailSpec {
    side: RailSide::Right,
};

fn required_command_rail_height(
    spec: &CommandRailSpec,
    metrics: UiMetrics,
) -> Result<i32, LayoutError> {
    let command_count = i32::try_from(spec.command_count()).map_err(|_| LayoutError::Overflow)?;
    let group_gaps =
        i32::try_from(spec.group_count().saturating_sub(1)).map_err(|_| LayoutError::Overflow)?;
    metrics
        .rail_padding
        .checked_mul(2)
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
    let mut y = metrics.rail_padding;
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
    for density in [RailDensity::Comfortable, RailDensity::Compact] {
        let metrics = density.metrics(dpi);
        if required_command_rail_height(&LEFT_RAIL, metrics)? <= available_height
            && required_command_rail_height(&RIGHT_RAIL, metrics)? <= available_height
        {
            return Ok(density);
        }
    }
    let required = required_command_rail_height(&LEFT_RAIL, RailDensity::Compact.metrics(dpi))?;
    Err(LayoutError::InsufficientHeight {
        required,
        available: available_height,
    })
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn minimum_main_client_height(dpi: u32, measured: MeasuredFontMetrics) -> i32 {
    let metrics = measured.rail_metrics(RailDensity::Compact, dpi);
    let left = required_command_rail_height(&LEFT_RAIL, metrics).unwrap_or(i32::MAX);
    let right = required_command_rail_height(&RIGHT_RAIL, metrics).unwrap_or(i32::MAX);
    left.max(right).saturating_add(measured.status_height(dpi))
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn recommended_main_client_height(dpi: u32, measured: MeasuredFontMetrics) -> i32 {
    let metrics = measured.rail_metrics(RailDensity::Comfortable, dpi);
    let left = required_command_rail_height(&LEFT_RAIL, metrics).unwrap_or(i32::MAX);
    let right = required_command_rail_height(&RIGHT_RAIL, metrics).unwrap_or(i32::MAX);
    left.max(right).saturating_add(measured.status_height(dpi))
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn calculate_main_layout(
    client_width: i32,
    client_height: i32,
    dpi: u32,
    measured: MeasuredFontMetrics,
) -> MainLayout {
    let width = client_width.max(0);
    let height = client_height.max(0);
    let status_height = measured.status_height(dpi).min(height);
    let rail_height = height.saturating_sub(status_height);

    let selected = [RailDensity::Comfortable, RailDensity::Compact]
        .into_iter()
        .find_map(|density| {
            let metrics = measured.rail_metrics(density, dpi);
            let rails_width = metrics.rail_width.saturating_mul(2);
            if rails_width >= width {
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
    let list_width = width.saturating_sub(rail_width.saturating_mul(2));
    MainLayout {
        rail_mode,
        rail_width,
        left_buttons,
        right_buttons,
        list: LayoutRect {
            x: rail_width,
            y: 0,
            width: list_width,
            height: rail_height,
        },
        status: LayoutRect {
            x: 0,
            y: rail_height,
            width,
            height: status_height,
        },
    }
}

/// Structured status content whose independent channels survive row refreshes.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct UiStatus {
    item_count: usize,
    transient: Option<String>,
    progress: Option<String>,
    recovery: Option<String>,
}

#[cfg(any(windows, test))]
impl UiStatus {
    #[must_use]
    pub(crate) fn with_recovery(message: impl Into<String>) -> Self {
        Self {
            recovery: Some(message.into()),
            ..Self::default()
        }
    }

    #[must_use]
    pub(crate) fn with_transient(message: impl Into<String>) -> Self {
        Self {
            transient: Some(message.into()),
            ..Self::default()
        }
    }

    pub(crate) fn set_item_count(&mut self, item_count: usize) {
        self.item_count = item_count;
    }

    pub(crate) fn set_transient(&mut self, message: impl Into<String>) {
        self.transient = Some(message.into());
    }

    pub(crate) fn set_progress(&mut self, message: impl Into<String>) {
        self.progress = Some(message.into());
    }

    pub(crate) fn set_recovery(&mut self, message: impl Into<String>) {
        self.recovery = Some(message.into());
    }

    pub(crate) fn clear_progress(&mut self) {
        self.progress = None;
    }

    pub(crate) fn clear_recovery(&mut self) {
        self.recovery = None;
    }

    #[must_use]
    pub(crate) fn text(&self) -> String {
        let mut parts = Vec::with_capacity(4);
        if let Some(message) = self.recovery.as_deref() {
            parts.push(message.to_owned());
        }
        if let Some(message) = self.progress.as_deref() {
            parts.push(message.to_owned());
        }
        if let Some(message) = self.transient.as_deref() {
            parts.push(message.to_owned());
        }
        parts.push(if self.item_count == 0 {
            EMPTY_LIST_STATUS.to_owned()
        } else {
            format!("{} 개", self.item_count)
        });
        parts.join("  |  ")
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn adaptive_primary_column_widths(available: i32, dpi: u32) -> [i32; 3] {
    let available = available.max(0);
    let location_minimum = scale_dip(LOCATION_COLUMN_MINIMUM, dpi).min(available);
    let names_available = available - location_minimum;
    let preferred_name = scale_dip(COLUMNS[0].default_width, dpi);
    let current = preferred_name.min((names_available + 1) / 2);
    let proposed = preferred_name.min(names_available - current);
    let location = available - current - proposed;
    [current, proposed, location]
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
    dpi: u32,
    columns: &[ColumnState; 7],
    scrollbar_allowance: i32,
) -> [i32; 3] {
    let optional_width = columns[3..]
        .iter()
        .filter(|column| column.visible)
        .map(|column| column.width_px(dpi))
        .fold(0_i32, i32::saturating_add);
    let budget = client_width
        .max(0)
        .saturating_sub(scrollbar_allowance.max(0))
        .saturating_sub(optional_width);
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
pub(crate) fn format_iec_file_size(bytes: u64) -> String {
    const UNITS: [&str; 7] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];
    if bytes < 1_024 {
        return format!("{bytes} B");
    }
    let mut unit = 0_usize;
    let mut divisor = 1_u128;
    while unit + 1 < UNITS.len() && u128::from(bytes) >= divisor.saturating_mul(1_024) {
        unit += 1;
        divisor = divisor.saturating_mul(1_024);
    }
    let mut tenths = (u128::from(bytes).saturating_mul(10) + divisor / 2) / divisor;
    if tenths >= 10_240 && unit + 1 < UNITS.len() {
        unit += 1;
        divisor = divisor.saturating_mul(1_024);
        tenths = (u128::from(bytes).saturating_mul(10) + divisor / 2) / divisor;
    }
    let whole = tenths / 10;
    let fraction = tenths % 10;
    if fraction == 0 {
        format!("{whole} {}", UNITS[unit])
    } else {
        format!("{whole}.{fraction} {}", UNITS[unit])
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn format_exact_bytes(bytes: u64) -> String {
    let digits = bytes.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index != 0 && (digits.len() - index).is_multiple_of(3) {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    format!("{grouped} bytes")
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn format_timestamp_fallback(date: [u16; 3], time: [u16; 3]) -> String {
    format!(
        "{}-{:02}-{:02} {:02}:{:02}:{:02}",
        date[0], date[1], date[2], time[0], time[1], time[2]
    )
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn minimum_content_width_dip() -> i32 {
    RailDensity::Comfortable.metrics(BASE_DPI).rail_width * 2
        + NAME_COLUMN_MINIMUM * 2
        + LOCATION_COLUMN_MINIMUM
        + LIST_SCROLLBAR_ALLOWANCE_DIP
}
/// Public product name used by the executable and user-facing diagnostics.
pub const PRODUCT_NAME: &str = "DarkReNamer";
/// Upstream behavior version targeted by compatibility mode.
pub const COMPATIBILITY_TARGET: &str = "DarkNamer 08.02.10";

/// Returns the product identity shown by the native About command.
#[must_use]
pub fn about_text() -> String {
    format!(
        "{PRODUCT_NAME} {}\n호환 대상: {COMPATIBILITY_TARGET}\n비공식 커뮤니티 관리 Rust 포트",
        env!("CARGO_PKG_VERSION")
    )
}

/// Native command identifier.
pub type CommandId = u16;

pub const APPLY: CommandId = 0x8003;
pub const REPLACE: CommandId = 0x8004;
pub const PREFIX: CommandId = 0x8005;
pub const SUFFIX: CommandId = 0x8006;
pub const CLEAR_NAME: CommandId = 0x8007;
pub const DELETE_POSITION: CommandId = 0x8008;
pub const DELETE_DELIMITED: CommandId = 0x8009;
pub const KEEP_DIGITS: CommandId = 0x800A;
pub const PAD_DIGITS: CommandId = 0x800B;
pub const SEQUENCE: CommandId = 0x800C;
pub const RESET: CommandId = 0x800D;
pub const CLEAR_LIST: CommandId = 0x800E;
pub const MANUAL_CHANGE: CommandId = 0x800F;
pub const SORT: CommandId = 0x8010;
pub const PARENT_PREFIX: CommandId = 0x8011;
pub const PARENT_SUFFIX: CommandId = 0x8012;
pub const UNIFY_PATH: CommandId = 0x8013;
pub const EXT_DELETE: CommandId = 0x8014;
pub const EXT_ADD: CommandId = 0x8015;
pub const EXT_REPLACE: CommandId = 0x8016;
pub const ADD_FILES: CommandId = 0x8017;
pub const COPY_NAMES: CommandId = 0x8018;
pub const SAVE_NAMES: CommandId = 0x8019;
pub const COPY_PATHS: CommandId = 0x801A;
pub const SAVE_PATHS: CommandId = 0x801B;
pub const IMPORT_NAMES: CommandId = 0x801C;
pub const IMPORT_PATHS: CommandId = 0x801D;
pub const MOVE_UP: CommandId = 0x801E;
pub const MOVE_DOWN: CommandId = 0x801F;
pub const SHOW_FULL_PATH: CommandId = 0x8020;
pub const SHOW_SIZE: CommandId = 0x8021;
pub const SHOW_MODIFIED: CommandId = 0x8022;
pub const SHOW_CREATED: CommandId = 0x8023;
pub const VERSION: CommandId = 0x8024;
pub(crate) const EXIT_COMMAND: CommandId = 2;
pub(crate) const DELETE_SELECTED_COMMAND: CommandId = 0xFFFF;

/// Placement of one command in a command rail. `None` means menu-only.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RailPlacement {
    pub side: RailSide,
    pub group: u8,
    pub order: u8,
}

/// Top-level native menu containing a catalog command.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum MenuGroup {
    File,
    Edit,
    View,
    Tools,
    About,
}

/// Placement of one command in a top-level native menu.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MenuPlacement {
    pub group: MenuGroup,
    /// Commands in different sections are separated visually.
    pub section: u8,
    pub order: u8,
}

/// Virtual keys used only for compatibility with the legacy UI contract.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacyVirtualKey {
    Character(u16),
    Delete,
    Escape,
    OemComma,
    OemPeriod,
}

/// Modifier combinations used by legacy compatibility accelerators.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacyShortcutModifiers {
    None,
    Control,
    ControlShift,
}

/// A legacy compatibility shortcut and its exact menu display text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LegacyShortcut {
    pub virtual_key: LegacyVirtualKey,
    pub modifiers: LegacyShortcutModifiers,
    pub display: &'static str,
}

/// A legacy compatibility accelerator resolved to a native command ID.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LegacyCommandShortcut {
    pub command: CommandId,
    pub shortcut: LegacyShortcut,
}

/// Data-dependent command enablement rule.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandEnableRule {
    Always,
    Rows,
    Selection,
    Never,
}

/// State boundary a command is allowed to mutate.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandMutationClass {
    None,
    Model,
    Filesystem,
}

/// Immutable native UI metadata for one command resource identifier.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandUiSpec {
    pub id: CommandId,
    pub rail: Option<RailPlacement>,
    pub rail_label: &'static str,
    pub menu: MenuPlacement,
    pub menu_label: &'static str,
    pub tooltip_label: &'static str,
    pub legacy_shortcut: Option<LegacyShortcut>,
    pub enable_rule: CommandEnableRule,
    pub mutation: CommandMutationClass,
    pub display: CommandUiPolicy,
}

impl CommandUiSpec {
    /// Returns the spoken one-line name exposed by a standard rail button's
    /// catalog-owned window text.
    #[must_use]
    pub fn rail_spoken_label(self) -> String {
        self.rail_label.replace('\n', " ")
    }
}

const fn rail(side: RailSide, group: u8, order: u8) -> Option<RailPlacement> {
    Some(RailPlacement { side, group, order })
}

const fn menu(group: MenuGroup, section: u8, order: u8) -> MenuPlacement {
    MenuPlacement {
        group,
        section,
        order,
    }
}

const fn legacy(
    virtual_key: LegacyVirtualKey,
    modifiers: LegacyShortcutModifiers,
    display: &'static str,
) -> Option<LegacyShortcut> {
    Some(LegacyShortcut {
        virtual_key,
        modifiers,
        display,
    })
}

macro_rules! command_ui_spec {
    ($id:ident, $rail:expr, $rail_label:literal, $menu:expr, $menu_label:literal,
     $tooltip:literal, $shortcut:expr, $enable:ident, $mutation:ident, $display:ident) => {
        CommandUiSpec {
            id: $id,
            rail: $rail,
            rail_label: $rail_label,
            menu: $menu,
            menu_label: $menu_label,
            tooltip_label: $tooltip,
            legacy_shortcut: $shortcut,
            enable_rule: CommandEnableRule::$enable,
            mutation: CommandMutationClass::$mutation,
            display: CommandUiPolicy::$display,
        }
    };
}

/// Complete native UI command catalog in stable resource-ID order.
pub const COMMAND_UI_SPECS: [CommandUiSpec; 34] = [
    command_ui_spec!(
        APPLY,
        rail(RailSide::Left, 0, 0),
        "변경\n적용",
        menu(MenuGroup::File, 1, 0),
        "실제 파일 변경",
        "변경 적용",
        legacy(
            LegacyVirtualKey::Character(b'S' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+S"
        ),
        Rows,
        Filesystem,
        NoRows
    ),
    command_ui_spec!(
        REPLACE,
        rail(RailSide::Left, 1, 0),
        "문자열\n바꾸기",
        menu(MenuGroup::Tools, 0, 0),
        "문자열 바꾸기",
        "문자열 바꾸기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PREFIX,
        rail(RailSide::Left, 1, 1),
        "앞이름\n붙이기",
        menu(MenuGroup::Tools, 0, 1),
        "앞이름 붙이기",
        "앞이름 붙이기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SUFFIX,
        rail(RailSide::Left, 1, 2),
        "뒷이름\n붙이기",
        menu(MenuGroup::Tools, 0, 2),
        "뒷이름 붙이기",
        "뒷이름 붙이기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_NAME,
        rail(RailSide::Left, 2, 0),
        "이름\n지우기",
        menu(MenuGroup::Tools, 1, 0),
        "이름 지우기",
        "이름 지우기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_POSITION,
        rail(RailSide::Left, 2, 1),
        "위치\n지우기",
        menu(MenuGroup::Tools, 1, 1),
        "위치 지우기",
        "위치 지우기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_DELIMITED,
        rail(RailSide::Left, 2, 2),
        "묶인곳\n지우기",
        menu(MenuGroup::Tools, 1, 2),
        "묶인곳 지우기",
        "묶인곳 지우기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        KEEP_DIGITS,
        rail(RailSide::Left, 3, 0),
        "숫자만\n남기기",
        menu(MenuGroup::Tools, 2, 0),
        "숫자만 남기기",
        "숫자만 남기기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PAD_DIGITS,
        rail(RailSide::Left, 3, 1),
        "자리수\n맞추기",
        menu(MenuGroup::Tools, 2, 1),
        "자리수 맞추기",
        "자리수 맞추기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SEQUENCE,
        rail(RailSide::Left, 3, 2),
        "번호\n붙이기",
        menu(MenuGroup::Tools, 2, 2),
        "번호 붙이기",
        "번호 붙이기",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        RESET,
        rail(RailSide::Right, 0, 0),
        "원래\n이름으로",
        menu(MenuGroup::File, 1, 1),
        "원래 이름으로",
        "원래 이름으로",
        legacy(
            LegacyVirtualKey::Character(b'Z' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+Z"
        ),
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_LIST,
        rail(RailSide::Right, 1, 0),
        "목록\n지우기",
        menu(MenuGroup::File, 1, 2),
        "경로목록 지우기",
        "목록 지우기",
        legacy(
            LegacyVirtualKey::Character(b'L' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+L"
        ),
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        MANUAL_CHANGE,
        rail(RailSide::Right, 1, 1),
        "직접\n바꾸기",
        menu(MenuGroup::Edit, 1, 0),
        "직접 바꾸기",
        "직접 바꾸기",
        None,
        Selection,
        Model,
        SingleRow
    ),
    command_ui_spec!(
        SORT,
        rail(RailSide::Right, 1, 2),
        "목록\n정렬",
        menu(MenuGroup::File, 1, 3),
        "경로목록 정렬",
        "목록 정렬",
        legacy(
            LegacyVirtualKey::Character(b'A' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+A"
        ),
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_PREFIX,
        rail(RailSide::Right, 2, 0),
        "경로명\n앞에",
        menu(MenuGroup::Tools, 4, 0),
        "경로명 앞에",
        "경로명 앞에",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_SUFFIX,
        rail(RailSide::Right, 2, 1),
        "경로명\n뒤에",
        menu(MenuGroup::Tools, 4, 1),
        "경로명 뒤에",
        "경로명 뒤에",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        UNIFY_PATH,
        None,
        "경로\n통일",
        menu(MenuGroup::Tools, 4, 2),
        "경로 통일하기 (미지원)",
        "경로 통일하기 (미지원)",
        None,
        Never,
        None,
        NoRows
    ),
    command_ui_spec!(
        EXT_DELETE,
        rail(RailSide::Right, 3, 0),
        "확장자\n삭제",
        menu(MenuGroup::Tools, 3, 0),
        "확장자 삭제",
        "확장자 삭제",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_ADD,
        rail(RailSide::Right, 3, 1),
        "확장자\n추가",
        menu(MenuGroup::Tools, 3, 1),
        "확장자 추가",
        "확장자 추가",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_REPLACE,
        rail(RailSide::Right, 3, 2),
        "확장자\n변경",
        menu(MenuGroup::Tools, 3, 2),
        "확장자 변경",
        "확장자 변경",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        ADD_FILES,
        None,
        "파일 추가",
        menu(MenuGroup::File, 0, 0),
        "경로목록에 파일 추가하기",
        "경로목록에 파일 추가하기",
        legacy(
            LegacyVirtualKey::Character(b'O' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+O"
        ),
        Always,
        Model,
        NoRows
    ),
    command_ui_spec!(
        COPY_NAMES,
        None,
        "이름 복사",
        menu(MenuGroup::File, 2, 0),
        "클립보드로 바꿀이름 복사",
        "클립보드로 바꿀이름 복사",
        legacy(
            LegacyVirtualKey::Character(b'C' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+C"
        ),
        Rows,
        None,
        NoRows
    ),
    command_ui_spec!(
        SAVE_NAMES,
        None,
        "이름 저장",
        menu(MenuGroup::File, 2, 1),
        "문서파일로 바꿀이름 저장",
        "문서파일로 바꿀이름 저장",
        legacy(
            LegacyVirtualKey::Character(b'X' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+X"
        ),
        Rows,
        Filesystem,
        NoRows
    ),
    command_ui_spec!(
        COPY_PATHS,
        None,
        "경로 복사",
        menu(MenuGroup::File, 3, 0),
        "클립보드로 경로목록 복사",
        "클립보드로 경로목록 복사",
        legacy(
            LegacyVirtualKey::Character(b'C' as u16),
            LegacyShortcutModifiers::ControlShift,
            "Ctrl+Shift+C"
        ),
        Rows,
        None,
        NoRows
    ),
    command_ui_spec!(
        SAVE_PATHS,
        None,
        "경로 저장",
        menu(MenuGroup::File, 3, 1),
        "문서파일로 경로목록 저장",
        "문서파일로 경로목록 저장",
        legacy(
            LegacyVirtualKey::Character(b'X' as u16),
            LegacyShortcutModifiers::ControlShift,
            "Ctrl+Shift+X"
        ),
        Rows,
        Filesystem,
        NoRows
    ),
    command_ui_spec!(
        IMPORT_NAMES,
        None,
        "이름 불러오기",
        menu(MenuGroup::File, 4, 0),
        "바꿀이름 불러오기",
        "바꿀이름 불러오기",
        legacy(
            LegacyVirtualKey::Character(b'V' as u16),
            LegacyShortcutModifiers::Control,
            "Ctrl+V"
        ),
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        IMPORT_PATHS,
        None,
        "경로 불러오기",
        menu(MenuGroup::File, 4, 1),
        "경로목록 불러오기",
        "경로목록 불러오기",
        legacy(
            LegacyVirtualKey::Character(b'V' as u16),
            LegacyShortcutModifiers::ControlShift,
            "Ctrl+Shift+V"
        ),
        Always,
        Model,
        NoRows
    ),
    command_ui_spec!(
        MOVE_UP,
        None,
        "위로 올림",
        menu(MenuGroup::Edit, 0, 0),
        "위로 올림",
        "위로 올림",
        legacy(
            LegacyVirtualKey::OemComma,
            LegacyShortcutModifiers::None,
            "<"
        ),
        Selection,
        Model,
        MovedRows
    ),
    command_ui_spec!(
        MOVE_DOWN,
        None,
        "아래로 내림",
        menu(MenuGroup::Edit, 0, 1),
        "아래로 내림",
        "아래로 내림",
        legacy(
            LegacyVirtualKey::OemPeriod,
            LegacyShortcutModifiers::None,
            ">"
        ),
        Selection,
        Model,
        MovedRows
    ),
    command_ui_spec!(
        SHOW_FULL_PATH,
        None,
        "전체 경로 표시",
        menu(MenuGroup::View, 0, 0),
        "전체 경로 표시",
        "전체 경로 표시",
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_SIZE,
        None,
        "파일 크기 표시",
        menu(MenuGroup::View, 0, 1),
        "파일 크기 표시",
        "파일 크기 표시",
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_MODIFIED,
        None,
        "변경 시각 표시",
        menu(MenuGroup::View, 0, 2),
        "변경 시각 표시",
        "변경 시각 표시",
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_CREATED,
        None,
        "생성 시각 표시",
        menu(MenuGroup::View, 0, 3),
        "생성 시각 표시",
        "생성 시각 표시",
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        VERSION,
        None,
        "버전",
        menu(MenuGroup::About, 0, 0),
        "버전(&H)",
        "버전",
        None,
        Always,
        None,
        NoRows
    ),
];

/// Legacy shell accelerators whose commands are outside APPLY..VERSION.
pub const LEGACY_AUXILIARY_SHORTCUTS: [LegacyCommandShortcut; 2] = [
    LegacyCommandShortcut {
        command: DELETE_SELECTED_COMMAND,
        shortcut: LegacyShortcut {
            virtual_key: LegacyVirtualKey::Delete,
            modifiers: LegacyShortcutModifiers::None,
            display: "Delete",
        },
    },
    LegacyCommandShortcut {
        command: EXIT_COMMAND,
        shortcut: LegacyShortcut {
            virtual_key: LegacyVirtualKey::Escape,
            modifiers: LegacyShortcutModifiers::None,
            display: "Esc",
        },
    },
];

/// Iterates every catalog and auxiliary legacy compatibility accelerator.
pub fn legacy_command_shortcuts() -> impl Iterator<Item = LegacyCommandShortcut> {
    COMMAND_UI_SPECS
        .iter()
        .filter_map(|spec| {
            spec.legacy_shortcut.map(|shortcut| LegacyCommandShortcut {
                command: spec.id,
                shortcut,
            })
        })
        .chain(LEGACY_AUXILIARY_SHORTCUTS)
}

/// Looks up a legacy compatibility accelerator by command identifier.
#[must_use]
pub fn legacy_command_shortcut(command: CommandId) -> Option<LegacyShortcut> {
    legacy_command_shortcuts()
        .find(|spec| spec.command == command)
        .map(|spec| spec.shortcut)
}

/// Looks up one command's immutable UI metadata.
#[must_use]
pub fn command_ui_spec(id: CommandId) -> Option<&'static CommandUiSpec> {
    let index = usize::from(id.checked_sub(APPLY)?);
    COMMAND_UI_SPECS.get(index).filter(|spec| spec.id == id)
}

/// Returns a menu label with its catalog-owned legacy shortcut display.
#[must_use]
pub fn command_menu_label(spec: &CommandUiSpec) -> String {
    spec.legacy_shortcut.map_or_else(
        || spec.menu_label.to_owned(),
        |shortcut| format!("{}\t{}", spec.menu_label, shortcut.display),
    )
}

/// Native UI work required after a command finishes.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum UiEffect {
    None,
    RowChanged(usize),
    RowsChanged(Box<[usize]>),
    AllRowsChanged,
    ColumnsChanged(usize),
    CloseRequested,
}

/// Resolved command result after model-change detection.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CommandOutcome {
    effect: UiEffect,
}

#[cfg(any(windows, test))]
impl CommandOutcome {
    pub(crate) const fn ui(effect: UiEffect) -> Self {
        Self { effect }
    }

    pub(crate) fn model(changed: bool, effect: UiEffect) -> Self {
        Self {
            effect: if changed { effect } else { UiEffect::None },
        }
    }

    pub(crate) fn into_effect(self) -> UiEffect {
        self.effect
    }
}

/// Maximum row-rendering scope for a native command.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandUiPolicy {
    NoRows,
    SingleRow,
    MovedRows,
    AllRows,
    Columns,
}

#[must_use]
pub fn command_ui_policy(command: CommandId) -> CommandUiPolicy {
    command_ui_spec(command).map_or_else(
        || {
            if command == DELETE_SELECTED_COMMAND {
                CommandUiPolicy::AllRows
            } else {
                CommandUiPolicy::NoRows
            }
        },
        |spec| spec.display,
    )
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn command_effect_fits_policy(command: CommandId, outcome: &CommandOutcome) -> bool {
    match &outcome.effect {
        UiEffect::None => true,
        UiEffect::RowChanged(_) => command_ui_policy(command) == CommandUiPolicy::SingleRow,
        UiEffect::RowsChanged(_) => command_ui_policy(command) == CommandUiPolicy::MovedRows,
        UiEffect::AllRowsChanged => command_ui_policy(command) == CommandUiPolicy::AllRows,
        UiEffect::ColumnsChanged(_) => command_ui_policy(command) == CommandUiPolicy::Columns,
        UiEffect::CloseRequested => command == EXIT_COMMAND,
    }
}

#[cfg(any(windows, test))]
pub(crate) fn changed_move_rows(before: &[usize], after: &[usize]) -> Box<[usize]> {
    let mut changed = before.iter().chain(after).copied().collect::<Vec<_>>();
    changed.sort_unstable();
    changed.dedup();
    changed.into_boxed_slice()
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
        label: "변경할 이름",
        default_width: 150,
    },
    ColumnSpec {
        label: "파일 위치",
        default_width: 100,
    },
    ColumnSpec {
        label: "전체경로",
        default_width: 0,
    },
    ColumnSpec {
        label: "파일크기",
        default_width: 0,
    },
    ColumnSpec {
        label: "변경시각",
        default_width: 0,
    },
    ColumnSpec {
        label: "생성시각",
        default_width: 0,
    },
];

/// Command with its visible native rail-button text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ToolSpec {
    pub id: CommandId,
    pub label: &'static str,
}

impl ToolSpec {
    /// Returns the one-line text used for tooltips and spoken command names.
    #[must_use]
    pub fn one_line_label(self) -> String {
        self.label.replace('\n', " ")
    }
}

/// Derives the visible rail tool data for one catalog command.
#[must_use]
pub fn rail_tool_spec(command: CommandId) -> Option<ToolSpec> {
    command_ui_spec(command).and_then(|spec| {
        spec.rail.map(|_| ToolSpec {
            id: spec.id,
            label: spec.rail_label,
        })
    })
}

/// Iterates the visible tool data for one rail in catalog order.
pub fn rail_tool_specs(spec: CommandRailSpec) -> impl Iterator<Item = ToolSpec> {
    spec.commands().filter_map(rail_tool_spec)
}

/// Whether a command is enabled for current list/selection state.
#[must_use]
pub fn command_enabled(id: CommandId, row_count: usize, selected_count: usize) -> bool {
    let Some(spec) = command_ui_spec(id) else {
        return id == EXIT_COMMAND;
    };
    match spec.enable_rule {
        CommandEnableRule::Always => true,
        CommandEnableRule::Rows => row_count > 0,
        CommandEnableRule::Selection => selected_count > 0,
        CommandEnableRule::Never => false,
    }
}

#[cfg(any(windows, test))]
pub(crate) fn compare_utf16_fallback(
    left: &darknamer_core::LegacyText,
    right: &darknamer_core::LegacyText,
) -> std::cmp::Ordering {
    left.units().cmp(right.units())
}

#[cfg(any(windows, test))]
const LISTVIEW_STATE_CHANGED: u32 = 0x0008;
#[cfg(any(windows, test))]
const LISTVIEW_SELECTED: u32 = 0x0002;

#[cfg(any(windows, test))]
#[must_use]
fn selection_command_state_changed(changed: u32, old_state: u32, new_state: u32) -> bool {
    changed & LISTVIEW_STATE_CHANGED != 0 && (old_state ^ new_state) & LISTVIEW_SELECTED != 0
}

#[cfg(windows)]
mod windows;

/// Runs the native application.
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(windows)]
    {
        windows::run().map_err(Into::into)
    }
    #[cfg(not(windows))]
    {
        Err("DarkReNamer is available only on Windows".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_ids_are_exact_contiguous_resource_values() {
        let ids = [
            APPLY,
            REPLACE,
            PREFIX,
            SUFFIX,
            CLEAR_NAME,
            DELETE_POSITION,
            DELETE_DELIMITED,
            KEEP_DIGITS,
            PAD_DIGITS,
            SEQUENCE,
            RESET,
            CLEAR_LIST,
            MANUAL_CHANGE,
            SORT,
            PARENT_PREFIX,
            PARENT_SUFFIX,
            UNIFY_PATH,
            EXT_DELETE,
            EXT_ADD,
            EXT_REPLACE,
            ADD_FILES,
            COPY_NAMES,
            SAVE_NAMES,
            COPY_PATHS,
            SAVE_PATHS,
            IMPORT_NAMES,
            IMPORT_PATHS,
            MOVE_UP,
            MOVE_DOWN,
            SHOW_FULL_PATH,
            SHOW_SIZE,
            SHOW_MODIFIED,
            SHOW_CREATED,
            VERSION,
        ];
        assert_eq!(ids, core::array::from_fn(|index| 0x8003 + index as u16));
    }

    #[test]
    fn command_catalog_is_complete_unique_and_resource_ordered() {
        assert_eq!(COMMAND_UI_SPECS.len(), usize::from(VERSION - APPLY + 1));
        assert_eq!(
            COMMAND_UI_SPECS.map(|spec| spec.id),
            core::array::from_fn(|index| APPLY + index as u16)
        );
        for spec in &COMMAND_UI_SPECS {
            assert_eq!(command_ui_spec(spec.id), Some(spec));
        }
        assert!(command_ui_spec(APPLY - 1).is_none());
        assert!(command_ui_spec(VERSION + 1).is_none());
    }

    #[test]
    fn catalog_menu_and_rail_placements_are_unique_and_ordered() {
        for group in [
            MenuGroup::File,
            MenuGroup::Edit,
            MenuGroup::View,
            MenuGroup::Tools,
            MenuGroup::About,
        ] {
            let mut placements = COMMAND_UI_SPECS
                .iter()
                .filter(|spec| spec.menu.group == group)
                .map(|spec| (spec.menu.section, spec.menu.order))
                .collect::<Vec<_>>();
            placements.sort_unstable();
            placements.dedup();
            assert_eq!(
                placements.len(),
                COMMAND_UI_SPECS
                    .iter()
                    .filter(|spec| spec.menu.group == group)
                    .count()
            );
        }
        for rail in [LEFT_RAIL, RIGHT_RAIL] {
            let placements = rail
                .command_specs()
                .filter_map(|spec| spec.rail)
                .map(|placement| (placement.group, placement.order))
                .collect::<Vec<_>>();
            assert!(placements.windows(2).all(|pair| pair[0] < pair[1]));
        }
        assert_eq!(command_ui_spec(UNIFY_PATH).and_then(|spec| spec.rail), None);
    }

    #[test]
    fn catalog_labels_cover_menu_tooltip_and_standard_button_accessibility() {
        for spec in &COMMAND_UI_SPECS {
            assert!(!spec.menu_label.is_empty());
            assert!(!spec.rail_label.is_empty());
            assert!(!spec.tooltip_label.is_empty());
            assert!(!spec.tooltip_label.contains('\n'));
            let menu_label = command_menu_label(spec);
            assert!(menu_label.starts_with(spec.menu_label));
            assert_eq!(menu_label.contains('\t'), spec.legacy_shortcut.is_some());
        }
        for rail in [LEFT_RAIL, RIGHT_RAIL] {
            for spec in rail.command_specs() {
                assert_eq!(spec.rail_spoken_label(), spec.tooltip_label);
            }
        }
    }

    #[test]
    fn catalog_classifies_enable_mutation_and_display_boundaries() {
        let apply = command_ui_spec(APPLY).copied();
        assert_eq!(
            apply.map(|spec| (spec.enable_rule, spec.mutation, spec.display)),
            Some((
                CommandEnableRule::Rows,
                CommandMutationClass::Filesystem,
                CommandUiPolicy::NoRows,
            ))
        );
        for command in [SAVE_NAMES, SAVE_PATHS] {
            assert_eq!(
                command_ui_spec(command).map(|spec| spec.mutation),
                Some(CommandMutationClass::Filesystem)
            );
        }
        assert_eq!(
            command_ui_spec(MANUAL_CHANGE).map(|spec| (
                spec.enable_rule,
                spec.mutation,
                spec.display
            )),
            Some((
                CommandEnableRule::Selection,
                CommandMutationClass::Model,
                CommandUiPolicy::SingleRow,
            ))
        );
        assert_eq!(
            command_ui_spec(UNIFY_PATH).map(|spec| (spec.enable_rule, spec.mutation, spec.display)),
            Some((
                CommandEnableRule::Never,
                CommandMutationClass::None,
                CommandUiPolicy::NoRows,
            ))
        );
    }

    #[test]
    fn exact_legacy_shortcuts_remain_explicit_compatibility_metadata() {
        let shortcut = |command| legacy_command_shortcut(command);
        assert_eq!(
            shortcut(SORT),
            legacy(
                LegacyVirtualKey::Character(b'A' as u16),
                LegacyShortcutModifiers::Control,
                "Ctrl+A"
            )
        );
        assert_eq!(
            shortcut(SAVE_NAMES),
            legacy(
                LegacyVirtualKey::Character(b'X' as u16),
                LegacyShortcutModifiers::Control,
                "Ctrl+X"
            )
        );
        assert_eq!(
            shortcut(IMPORT_NAMES),
            legacy(
                LegacyVirtualKey::Character(b'V' as u16),
                LegacyShortcutModifiers::Control,
                "Ctrl+V"
            )
        );
        assert_eq!(
            shortcut(EXIT_COMMAND),
            legacy(
                LegacyVirtualKey::Escape,
                LegacyShortcutModifiers::None,
                "Esc"
            )
        );
        assert_eq!(
            shortcut(MOVE_UP).map(|value| value.virtual_key),
            Some(LegacyVirtualKey::OemComma)
        );
        assert_eq!(
            shortcut(MOVE_DOWN).map(|value| value.virtual_key),
            Some(LegacyVirtualKey::OemPeriod)
        );
    }

    #[test]
    fn command_ui_policy_keeps_non_model_commands_out_of_row_rendering() {
        for command in [
            APPLY,
            ADD_FILES,
            COPY_NAMES,
            COPY_PATHS,
            SAVE_NAMES,
            SAVE_PATHS,
            IMPORT_PATHS,
            UNIFY_PATH,
            VERSION,
        ] {
            assert_eq!(command_ui_policy(command), CommandUiPolicy::NoRows);
        }
    }

    #[test]
    fn command_ui_policy_limits_local_changes_and_classifies_transforms() {
        assert_eq!(command_ui_policy(MANUAL_CHANGE), CommandUiPolicy::SingleRow);
        for command in [MOVE_UP, MOVE_DOWN] {
            assert_eq!(command_ui_policy(command), CommandUiPolicy::MovedRows);
        }
        for command in [SHOW_FULL_PATH, SHOW_SIZE, SHOW_MODIFIED, SHOW_CREATED] {
            assert_eq!(command_ui_policy(command), CommandUiPolicy::Columns);
        }
        for command in [
            RESET,
            CLEAR_LIST,
            REPLACE,
            PREFIX,
            SUFFIX,
            CLEAR_NAME,
            DELETE_POSITION,
            DELETE_DELIMITED,
            KEEP_DIGITS,
            PAD_DIGITS,
            SEQUENCE,
            SORT,
            PARENT_PREFIX,
            PARENT_SUFFIX,
            EXT_DELETE,
            EXT_ADD,
            EXT_REPLACE,
            IMPORT_NAMES,
        ] {
            assert_eq!(command_ui_policy(command), CommandUiPolicy::AllRows);
        }
    }

    #[test]
    fn unchanged_model_outcome_suppresses_requested_row_effect() {
        let outcome = CommandOutcome::model(false, UiEffect::AllRowsChanged);
        assert_eq!(outcome.into_effect(), UiEffect::None);

        let changed = CommandOutcome::model(true, UiEffect::RowChanged(42));
        assert_eq!(changed.into_effect(), UiEffect::RowChanged(42));

        for effect in [
            UiEffect::RowsChanged(vec![2, 3].into_boxed_slice()),
            UiEffect::ColumnsChanged(1),
            UiEffect::CloseRequested,
        ] {
            assert_ne!(CommandOutcome::ui(effect).into_effect(), UiEffect::None);
        }
    }

    #[test]
    fn command_outcomes_cannot_exceed_their_classified_render_scope() {
        assert!(command_effect_fits_policy(
            MANUAL_CHANGE,
            &CommandOutcome::ui(UiEffect::RowChanged(7))
        ));
        assert!(command_effect_fits_policy(
            MOVE_DOWN,
            &CommandOutcome::ui(UiEffect::RowsChanged(vec![6, 7].into_boxed_slice()))
        ));
        assert!(command_effect_fits_policy(
            SHOW_SIZE,
            &CommandOutcome::ui(UiEffect::ColumnsChanged(1))
        ));
        assert!(!command_effect_fits_policy(
            COPY_NAMES,
            &CommandOutcome::ui(UiEffect::AllRowsChanged)
        ));
    }

    #[test]
    fn move_effect_renders_only_old_and_new_row_positions() {
        assert_eq!(&*changed_move_rows(&[3], &[2]), &[2, 3]);
        assert_eq!(&*changed_move_rows(&[1, 3], &[0, 2]), &[0, 1, 2, 3]);
        assert_eq!(&*changed_move_rows(&[4, 5], &[4, 5]), &[4, 5]);
    }

    #[test]
    fn about_text_separates_product_version_from_compatibility_target() {
        let text = about_text();
        assert!(text.contains(concat!("DarkReNamer ", env!("CARGO_PKG_VERSION"))));
        assert!(text.contains("호환 대상: DarkNamer 08.02.10"));
        assert!(text.contains("비공식"));
    }

    #[test]
    fn dpi_scaling_is_rounded_and_monotonic() {
        assert_eq!(scale_dip(44, 96), 44);
        assert_eq!(scale_dip(44, 120), 55);
        assert_eq!(scale_dip(44, 144), 66);
        assert_eq!(scale_dip(44, 192), 88);
        assert_eq!(scale_dip(-13, 120), -16);
        assert!(scale_dip(150, 120) < scale_dip(150, 144));
    }

    #[test]
    fn command_rail_specs_cover_each_visible_command_once() {
        assert_eq!(LEFT_RAIL.command_count(), 10);
        assert_eq!(RIGHT_RAIL.command_count(), 9);

        let mut commands = LEFT_RAIL
            .commands()
            .chain(RIGHT_RAIL.commands())
            .collect::<Vec<_>>();
        commands.sort_unstable();
        commands.dedup();

        assert_eq!(commands.len(), 19);
        assert!(!commands.contains(&UNIFY_PATH));
    }

    #[test]
    fn every_visible_command_has_button_and_one_line_tooltip_text() {
        for spec in [LEFT_RAIL, RIGHT_RAIL] {
            for tool in rail_tool_specs(spec) {
                assert!(!tool.label.is_empty());
                let one_line = tool.one_line_label();
                assert!(!one_line.is_empty());
                assert!(!one_line.contains('\n'));
            }
        }
    }

    #[test]
    fn command_rail_layout_has_exact_group_gaps_without_overlap() -> Result<(), LayoutError> {
        let metrics = RailDensity::Comfortable.metrics(96);
        let placements = calculate_command_rail_layout(&LEFT_RAIL, 352, metrics)?;

        assert_eq!(placements.len(), 10);
        assert!(placements.iter().all(|placement| {
            placement.x == 0
                && placement.width == 52
                && placement.height == 32
                && placement.bottom() <= 348
        }));
        assert!(
            placements
                .windows(2)
                .all(|pair| pair[0].bottom() <= pair[1].y)
        );
        assert_eq!(
            placements.last().map(|placement| placement.bottom()),
            Some(348)
        );
        assert_eq!(placements[9].bottom() + 4, 352);

        for start in [1, 4, 7] {
            assert_eq!(
                placements[start].y - placements[start - 1].bottom(),
                metrics.group_gap
            );
        }

        let right = calculate_command_rail_layout(&RIGHT_RAIL, 352, metrics)?;
        for start in [1, 4, 6] {
            assert_eq!(
                right[start].y - right[start - 1].bottom(),
                metrics.group_gap
            );
        }
        Ok(())
    }

    #[test]
    fn command_rail_metrics_scale_at_supported_dpis() {
        assert_eq!(
            [96, 120, 144, 192].map(|dpi| RailDensity::Comfortable.metrics(dpi)),
            [
                UiMetrics {
                    rail_padding: 4,
                    button_height: 32,
                    group_gap: 8,
                    rail_width: 52
                },
                UiMetrics {
                    rail_padding: 5,
                    button_height: 40,
                    group_gap: 10,
                    rail_width: 65
                },
                UiMetrics {
                    rail_padding: 6,
                    button_height: 48,
                    group_gap: 12,
                    rail_width: 78
                },
                UiMetrics {
                    rail_padding: 8,
                    button_height: 64,
                    group_gap: 16,
                    rail_width: 104
                },
            ]
        );
    }

    #[test]
    fn compact_rail_keeps_the_longest_two_line_label_width() {
        assert_eq!(RailDensity::Compact.metrics(96).rail_width, 52);
        assert_eq!(RailDensity::Compact.metrics(192).rail_width, 104);
        assert_eq!(
            rail_tool_spec(RESET).map(|tool| tool.label),
            Some("원래\n이름으로")
        );
    }

    #[test]
    fn command_rail_density_falls_back_and_reports_insufficient_height() {
        assert_eq!(
            select_command_rail_density(352, 96),
            Ok(RailDensity::Comfortable)
        );
        assert_eq!(
            select_command_rail_density(351, 96),
            Ok(RailDensity::Compact)
        );
        assert_eq!(
            select_command_rail_density(296, 96),
            Ok(RailDensity::Compact)
        );
        assert_eq!(
            select_command_rail_density(295, 96),
            Err(LayoutError::InsufficientHeight {
                required: 296,
                available: 295,
            })
        );
    }

    #[test]
    fn measured_font_metrics_expand_rail_and_status_geometry() {
        let measured = MeasuredFontMetrics {
            button_text_width: 90,
            button_text_height: 44,
            status_text_height: 24,
        };

        let compact = measured.rail_metrics(RailDensity::Compact, 96);
        assert!(compact.rail_width >= 100);
        assert!(compact.button_height >= 50);
        assert!(measured.status_height(96) >= 28);
        assert!(
            minimum_main_client_height(96, measured)
                > minimum_main_client_height(96, MeasuredFontMetrics::default())
        );
        assert!(
            recommended_main_client_height(96, measured) > minimum_main_client_height(96, measured)
        );
    }

    #[test]
    fn main_layout_falls_back_from_compact_to_menu_only_without_invalid_rectangles() {
        let measured = MeasuredFontMetrics::default();
        let comfortable = calculate_main_layout(464, 370, 96, measured);
        assert_eq!(comfortable.rail_mode, RailMode::Comfortable);

        let compact = calculate_main_layout(464, 369, 96, measured);
        assert_eq!(compact.rail_mode, RailMode::Compact);

        let vertical_menu_only = calculate_main_layout(464, 313, 96, measured);
        assert_eq!(vertical_menu_only.rail_mode, RailMode::MenuOnly);

        let menu_only = calculate_main_layout(80, 40, 96, measured);
        assert_eq!(menu_only.rail_mode, RailMode::MenuOnly);
        for rect in [menu_only.list, menu_only.status] {
            assert!(rect.x >= 0);
            assert!(rect.y >= 0);
            assert!(rect.width >= 0);
            assert!(rect.height >= 0);
        }
        assert_eq!(menu_only.list.width, 80);
        assert_eq!(menu_only.status.width, 80);
        assert_eq!(menu_only.list.height + menu_only.status.height, 40);
    }

    #[test]
    fn item_count_refresh_does_not_erase_structured_status_messages() {
        assert!(
            UiStatus::with_transient("시작 알림")
                .text()
                .contains("시작 알림")
        );
        let mut status = UiStatus::with_recovery("복구 상태를 확인하세요.");
        status.set_transient("2개 경로를 제외했습니다.");
        status.set_progress("파일 이름 변경 중: 3/10 단계");
        status.set_item_count(120);

        let rendered = status.text();
        assert!(rendered.contains("복구 상태를 확인하세요."));
        assert!(rendered.contains("2개 경로를 제외했습니다."));
        assert!(rendered.contains("파일 이름 변경 중: 3/10 단계"));
        assert!(rendered.contains("120 개"));

        status.set_item_count(121);
        let refreshed = status.text();
        assert!(refreshed.contains("2개 경로를 제외했습니다."));
        assert!(refreshed.contains("파일 이름 변경 중: 3/10 단계"));
        assert!(refreshed.contains("121 개"));

        status.clear_progress();
        status.clear_recovery();
        status.set_recovery("새 복구 상태");
        let settled = status.text();
        assert!(!settled.contains("복구 상태를 확인하세요."));
        assert!(!settled.contains("파일 이름 변경 중"));
        assert!(settled.contains("2개 경로를 제외했습니다."));
        assert!(settled.contains("새 복구 상태"));
    }

    #[test]
    fn directory_prompt_closes_and_unknown_results_cancel() {
        assert_eq!(directory_prompt_choice(6), DirectoryPromptChoice::Direct);
        assert_eq!(directory_prompt_choice(7), DirectoryPromptChoice::Recurse);
        for result in [0, 1, 2, 42] {
            assert_eq!(
                directory_prompt_choice(result),
                DirectoryPromptChoice::Cancel
            );
        }
    }

    #[test]
    fn prompt_layout_grows_for_measured_text_and_active_fields() {
        let compact = calculate_prompt_layout(
            96,
            PromptFontMetrics {
                title_width: 120,
                title_height: 18,
                label_width: 44,
                label_height: 18,
                line_height: 18,
            },
            PromptFields {
                value_one: false,
                value_two: false,
                choice: true,
            },
            LayoutRect {
                x: 0,
                y: 0,
                width: 1_920,
                height: 1_080,
            },
        );
        let expanded = calculate_prompt_layout(
            96,
            PromptFontMetrics {
                title_width: 520,
                title_height: 54,
                label_width: 96,
                label_height: 30,
                line_height: 30,
            },
            PromptFields {
                value_one: true,
                value_two: true,
                choice: true,
            },
            LayoutRect {
                x: 0,
                y: 0,
                width: 1_920,
                height: 1_080,
            },
        );

        assert!(expanded.client.width > compact.client.width);
        assert!(expanded.client.height > compact.client.height);
        assert!(expanded.title.height >= 54);
        assert!(expanded.edit_one.is_some());
        assert!(expanded.edit_two.is_some());
        assert!(expanded.choice.is_some());
        assert!(
            expanded
                .edit_two
                .is_some_and(|field| expanded.separator.y > field.y)
        );
        assert!(expanded.ok.bottom() <= expanded.client.height);
        assert!(expanded.cancel.bottom() <= expanded.client.height);
    }

    #[test]
    fn prompt_layout_keeps_every_active_child_inside_bounded_client() {
        let bounds = LayoutRect {
            x: 0,
            y: 0,
            width: 360,
            height: 260,
        };
        let layout = calculate_prompt_layout(
            192,
            PromptFontMetrics {
                title_width: 1_200,
                title_height: 180,
                label_width: 400,
                label_height: 144,
                line_height: 72,
            },
            PromptFields {
                value_one: true,
                value_two: true,
                choice: true,
            },
            bounds,
        );
        let active = [
            Some(layout.title),
            layout.edit_one,
            layout.label_one,
            layout.edit_two,
            layout.label_two,
            layout.choice,
            Some(layout.separator),
            Some(layout.ok),
            Some(layout.cancel),
        ];

        assert!(layout.client.width <= bounds.width);
        assert!(layout.client.height <= bounds.height);
        for rect in active.into_iter().flatten() {
            assert!(rect.x >= 0);
            assert!(rect.y >= 0);
            assert!(rect.width >= 0);
            assert!(rect.height >= 0);
            assert!(rect.x.saturating_add(rect.width) <= layout.client.width);
            assert!(rect.bottom() <= layout.client.height);
        }
    }

    #[test]
    fn adaptive_primary_columns_fit_command_rail_minimum() {
        assert_eq!(minimum_content_width_dip(), 441);

        for (dpi, available, expected) in [
            (96, 320, [120, 120, 80]),
            (96, 360, [140, 140, 80]),
            (96, 400, [150, 150, 100]),
            (120, 400, [150, 150, 100]),
            (144, 480, [180, 180, 120]),
            (192, 640, [240, 240, 160]),
        ] {
            let widths = adaptive_primary_column_widths(available, dpi);
            assert_eq!(widths, expected);
            assert_eq!(widths.iter().sum::<i32>(), available);
        }
    }

    #[test]
    fn column_state_preserves_user_width_across_dpi_changes() {
        let mut column = ColumnState::visible(150);

        column.record_user_resize(300, 144);

        assert!(column.visible);
        assert!(column.user_resized);
        assert_eq!(column.width_dip, 200);
        assert_eq!(column.width_px(192), 400);
        column.set_visible(false);
        assert!(!column.visible);
        assert_eq!(column.width_dip, 200);
        assert!(column.user_resized);
    }

    #[test]
    fn optional_columns_reduce_the_primary_width_budget() {
        let mut columns = default_column_states();
        columns[3].set_visible(true);

        let widths = allocate_primary_column_widths(457, 96, &columns, 17);

        assert_eq!(widths, [120, 120, 80]);
        assert_eq!(widths.iter().sum::<i32>(), 320);
    }

    #[test]
    fn narrow_width_keeps_user_resized_columns_and_allows_overflow() {
        let mut columns = default_column_states();
        columns[0].record_user_resize(220, 96);

        let widths = allocate_primary_column_widths(300, 96, &columns, 17);

        assert_eq!(widths, [220, 120, 80]);
        assert!(widths.iter().sum::<i32>() > 300 - 17);
    }

    #[test]
    fn iec_file_size_formatting_handles_unit_boundaries() {
        for (bytes, expected) in [
            (0, "0 B"),
            (1, "1 B"),
            (1_023, "1023 B"),
            (1_024, "1 KiB"),
            (1_536, "1.5 KiB"),
            (10_240, "10 KiB"),
            (1_048_575, "1 MiB"),
            (1_048_576, "1 MiB"),
            (1_073_741_823, "1 GiB"),
            (1_073_741_824, "1 GiB"),
        ] {
            assert_eq!(format_iec_file_size(bytes), expected);
        }
        assert_eq!(format_exact_bytes(134_637_824), "134,637,824 bytes");
    }

    #[test]
    fn timestamp_fallback_is_fixed_width_and_deterministic() {
        assert_eq!(
            format_timestamp_fallback([2026, 8, 29], [16, 30, 0]),
            "2026-08-29 16:30:00"
        );
    }

    #[test]
    fn widened_window_stays_inside_the_nearest_monitor_work_area() {
        assert_eq!(
            fit_widened_window_to_work_area(1_456, 0, 1_920, 560),
            Some(HorizontalWindowPlacement {
                x: 1_360,
                width: 560,
            })
        );
        assert_eq!(
            fit_widened_window_to_work_area(-80, 0, 1_920, 560),
            Some(HorizontalWindowPlacement { x: 0, width: 560 })
        );
        assert_eq!(
            fit_widened_window_to_work_area(200, 0, 480, 560),
            Some(HorizontalWindowPlacement { x: 0, width: 480 })
        );
        assert_eq!(fit_widened_window_to_work_area(0, 10, 10, 560), None);
    }

    #[test]
    fn native_empty_state_and_menu_copy_are_exact() {
        assert_eq!(
            EMPTY_LIST_STATUS,
            "파일이나 폴더를 끌어 놓거나 Ctrl+O로 추가하세요."
        );
        assert_eq!(
            command_ui_spec(VERSION).map(|spec| spec.menu_label),
            Some("버전(&H)")
        );
        assert_eq!(
            COLUMNS.map(|column| column.label),
            [
                "현재 이름",
                "변경할 이름",
                "파일 위치",
                "전체경로",
                "파일크기",
                "변경시각",
                "생성시각",
            ]
        );
    }

    #[test]
    fn layout_columns_and_command_order_match_specs() {
        assert_eq!(
            (INITIAL_WIDTH, INITIAL_HEIGHT, STATUS_HEIGHT),
            (464, 408, 18)
        );
        assert_eq!(
            COLUMNS.map(|column| column.default_width),
            [150, 150, 100, 0, 0, 0, 0]
        );
        assert_eq!(
            LEFT_RAIL.commands().collect::<Vec<_>>(),
            [
                APPLY,
                REPLACE,
                PREFIX,
                SUFFIX,
                CLEAR_NAME,
                DELETE_POSITION,
                DELETE_DELIMITED,
                KEEP_DIGITS,
                PAD_DIGITS,
                SEQUENCE
            ]
            .to_vec()
        );
        assert_eq!(
            RIGHT_RAIL.commands().collect::<Vec<_>>(),
            [
                RESET,
                CLEAR_LIST,
                MANUAL_CHANGE,
                SORT,
                PARENT_PREFIX,
                PARENT_SUFFIX,
                EXT_DELETE,
                EXT_ADD,
                EXT_REPLACE
            ]
            .to_vec()
        );
    }

    #[test]
    fn menu_state_requires_rows_and_selection_like_original() {
        assert!(command_enabled(ADD_FILES, 0, 0));
        assert!(command_enabled(IMPORT_PATHS, 0, 0));
        assert!(command_enabled(SHOW_FULL_PATH, 0, 0));
        assert!(command_enabled(VERSION, 0, 0));
        assert!(command_enabled(2, 0, 0));
        assert!(!command_enabled(APPLY, 0, 0));
        assert!(command_enabled(APPLY, 1, 0));
        assert!(!command_enabled(UNIFY_PATH, 1, 0));
        assert!(!command_enabled(MANUAL_CHANGE, 1, 0));
        assert!(command_enabled(MANUAL_CHANGE, 1, 1));
    }

    #[test]
    fn utf16_fallback_never_treats_distinct_values_as_equal() {
        assert_eq!(
            compare_utf16_fallback(&"File.txt".into(), &"file.txt".into()),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            compare_utf16_fallback(&"same.txt".into(), &"same.txt".into()),
            std::cmp::Ordering::Equal
        );
    }

    #[test]
    fn listview_selection_changes_refresh_selection_commands() {
        assert!(selection_command_state_changed(
            LISTVIEW_STATE_CHANGED,
            0,
            LISTVIEW_SELECTED
        ));
        assert!(selection_command_state_changed(
            LISTVIEW_STATE_CHANGED,
            LISTVIEW_SELECTED,
            0
        ));
    }

    #[test]
    fn unrelated_listview_changes_do_not_refresh_selection_commands() {
        assert!(!selection_command_state_changed(0, 0, LISTVIEW_SELECTED));
        assert!(!selection_command_state_changed(
            LISTVIEW_STATE_CHANGED,
            LISTVIEW_SELECTED,
            LISTVIEW_SELECTED | 0x0001
        ));
    }
}
