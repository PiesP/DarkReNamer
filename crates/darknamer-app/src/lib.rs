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
pub(crate) const EMPTY_LIST_STATUS: &str = "파일이나 폴더를 끌어 놓거나 Ctrl+O로 추가하세요.";
#[cfg(any(windows, test))]
pub(crate) const VERSION_MENU_LABEL: &str = "버전(&H)";

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

/// One logical group of commands in a vertical command rail.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandGroupSpec {
    pub commands: &'static [CommandId],
}

/// Ordered command groups for one side of the main window.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandRailSpec {
    pub groups: &'static [CommandGroupSpec],
}

impl CommandRailSpec {
    /// Returns the total number of visible commands in this rail.
    #[must_use]
    pub fn command_count(self) -> usize {
        self.groups.iter().map(|group| group.commands.len()).sum()
    }

    /// Iterates over visible command identifiers in display order.
    pub fn commands(self) -> impl Iterator<Item = CommandId> {
        self.groups
            .iter()
            .flat_map(|group| group.commands.iter().copied())
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

const LEFT_RAIL_GROUP_1: [CommandId; 1] = [APPLY];
const LEFT_RAIL_GROUP_2: [CommandId; 3] = [REPLACE, PREFIX, SUFFIX];
const LEFT_RAIL_GROUP_3: [CommandId; 3] = [CLEAR_NAME, DELETE_POSITION, DELETE_DELIMITED];
const LEFT_RAIL_GROUP_4: [CommandId; 3] = [KEEP_DIGITS, PAD_DIGITS, SEQUENCE];
const LEFT_RAIL_GROUPS: [CommandGroupSpec; 4] = [
    CommandGroupSpec {
        commands: &LEFT_RAIL_GROUP_1,
    },
    CommandGroupSpec {
        commands: &LEFT_RAIL_GROUP_2,
    },
    CommandGroupSpec {
        commands: &LEFT_RAIL_GROUP_3,
    },
    CommandGroupSpec {
        commands: &LEFT_RAIL_GROUP_4,
    },
];

const RIGHT_RAIL_GROUP_1: [CommandId; 1] = [RESET];
const RIGHT_RAIL_GROUP_2: [CommandId; 3] = [CLEAR_LIST, MANUAL_CHANGE, SORT];
const RIGHT_RAIL_GROUP_3: [CommandId; 2] = [PARENT_PREFIX, PARENT_SUFFIX];
const RIGHT_RAIL_GROUP_4: [CommandId; 3] = [EXT_DELETE, EXT_ADD, EXT_REPLACE];
const RIGHT_RAIL_GROUPS: [CommandGroupSpec; 4] = [
    CommandGroupSpec {
        commands: &RIGHT_RAIL_GROUP_1,
    },
    CommandGroupSpec {
        commands: &RIGHT_RAIL_GROUP_2,
    },
    CommandGroupSpec {
        commands: &RIGHT_RAIL_GROUP_3,
    },
    CommandGroupSpec {
        commands: &RIGHT_RAIL_GROUP_4,
    },
];

/// Explicit left-side command grouping.
pub const LEFT_RAIL: CommandRailSpec = CommandRailSpec {
    groups: &LEFT_RAIL_GROUPS,
};
/// Explicit right-side command grouping.
pub const RIGHT_RAIL: CommandRailSpec = CommandRailSpec {
    groups: &RIGHT_RAIL_GROUPS,
};

fn required_command_rail_height(
    spec: &CommandRailSpec,
    metrics: UiMetrics,
) -> Result<i32, LayoutError> {
    let command_count = i32::try_from(spec.command_count()).map_err(|_| LayoutError::Overflow)?;
    let group_gaps =
        i32::try_from(spec.groups.len().saturating_sub(1)).map_err(|_| LayoutError::Overflow)?;
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
    for (group_index, group) in spec.groups.iter().enumerate() {
        if group_index > 0 {
            y = y
                .checked_add(metrics.group_gap)
                .ok_or(LayoutError::Overflow)?;
        }
        for &command in group.commands {
            placements.push(CommandPlacement {
                command,
                x: 0,
                y,
                width: metrics.rail_width,
                height: metrics.button_height,
            });
            y = y
                .checked_add(metrics.button_height)
                .ok_or(LayoutError::Overflow)?;
        }
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
#[must_use]
pub(crate) const fn minimum_content_width_dip() -> i32 {
    RailDensity::Comfortable.metrics(BASE_DPI).rail_width * 2
        + NAME_COLUMN_MINIMUM * 2
        + LOCATION_COLUMN_MINIMUM
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

pub const LEFT_TOOLS: [ToolSpec; 10] = [
    ToolSpec {
        id: APPLY,
        label: "변경\n적용",
    },
    ToolSpec {
        id: REPLACE,
        label: "문자열\n바꾸기",
    },
    ToolSpec {
        id: PREFIX,
        label: "앞이름\n붙이기",
    },
    ToolSpec {
        id: SUFFIX,
        label: "뒷이름\n붙이기",
    },
    ToolSpec {
        id: CLEAR_NAME,
        label: "이름\n지우기",
    },
    ToolSpec {
        id: DELETE_POSITION,
        label: "위치\n지우기",
    },
    ToolSpec {
        id: DELETE_DELIMITED,
        label: "묶인곳\n지우기",
    },
    ToolSpec {
        id: KEEP_DIGITS,
        label: "숫자만\n남기기",
    },
    ToolSpec {
        id: PAD_DIGITS,
        label: "자리수\n맞추기",
    },
    ToolSpec {
        id: SEQUENCE,
        label: "번호\n붙이기",
    },
];

pub const RIGHT_TOOLS: [ToolSpec; 10] = [
    ToolSpec {
        id: RESET,
        label: "원래\n이름으로",
    },
    ToolSpec {
        id: CLEAR_LIST,
        label: "목록\n지우기",
    },
    ToolSpec {
        id: MANUAL_CHANGE,
        label: "직접\n바꾸기",
    },
    ToolSpec {
        id: SORT,
        label: "목록\n정렬",
    },
    ToolSpec {
        id: PARENT_PREFIX,
        label: "경로명\n앞에",
    },
    ToolSpec {
        id: PARENT_SUFFIX,
        label: "경로명\n뒤에",
    },
    ToolSpec {
        id: UNIFY_PATH,
        label: "경로\n통일",
    },
    ToolSpec {
        id: EXT_DELETE,
        label: "확장자\n삭제",
    },
    ToolSpec {
        id: EXT_ADD,
        label: "확장자\n추가",
    },
    ToolSpec {
        id: EXT_REPLACE,
        label: "확장자\n변경",
    },
];

/// Whether a command is enabled for current list/selection state.
#[must_use]
pub fn command_enabled(id: CommandId, row_count: usize, selected_count: usize) -> bool {
    match id {
        2 | ADD_FILES | IMPORT_PATHS | SHOW_FULL_PATH | SHOW_SIZE | SHOW_MODIFIED
        | SHOW_CREATED | VERSION => true,
        UNIFY_PATH => false,
        MANUAL_CHANGE | MOVE_UP | MOVE_DOWN => selected_count > 0,
        _ => row_count > 0,
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
        for (spec, tools) in [
            (&LEFT_RAIL, LEFT_TOOLS.as_slice()),
            (&RIGHT_RAIL, RIGHT_TOOLS.as_slice()),
        ] {
            for command in spec.commands() {
                let matches = tools
                    .iter()
                    .filter(|tool| tool.id == command)
                    .collect::<Vec<_>>();
                assert_eq!(matches.len(), 1);
                assert!(!matches[0].label.is_empty());
                let one_line = matches[0].one_line_label();
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
        assert_eq!(RIGHT_TOOLS[0].label, "원래\n이름으로");
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
    fn adaptive_primary_columns_fit_command_rail_minimum() {
        assert_eq!(minimum_content_width_dip(), 424);

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
        assert_eq!(VERSION_MENU_LABEL, "버전(&H)");
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
            LEFT_TOOLS.map(|tool| tool.id),
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
        );
        assert_eq!(
            RIGHT_TOOLS.map(|tool| tool.id),
            [
                RESET,
                CLEAR_LIST,
                MANUAL_CHANGE,
                SORT,
                PARENT_PREFIX,
                PARENT_SUFFIX,
                UNIFY_PATH,
                EXT_DELETE,
                EXT_ADD,
                EXT_REPLACE
            ]
        );
        assert_eq!(
            LEFT_RAIL.commands().collect::<Vec<_>>(),
            LEFT_TOOLS.map(|tool| tool.id)
        );
        assert_eq!(
            RIGHT_RAIL.commands().collect::<Vec<_>>(),
            RIGHT_TOOLS
                .into_iter()
                .filter(|tool| tool.id != UNIFY_PATH)
                .map(|tool| tool.id)
                .collect::<Vec<_>>()
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
