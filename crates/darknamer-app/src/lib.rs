//! Native Win32 shell and stable DarkNamer 08.02.10 UI contract.

#![cfg_attr(not(windows), forbid(unsafe_code))]

/// Bounded filesystem admission for native picker, drop, and path import.
pub mod admission;
/// Bounded shell-icon cache key derivation.
pub mod icon_cache;
#[cfg(any(windows, test))]
mod preview;
/// Safe rename planning and execution foundation.
pub mod rename;

#[cfg(windows)]
pub(crate) use preview::{
    PreviewCountCache, PreviewCounts, PreviewIssueCache, PreviewRowIssue,
    preview_status_delta_rows, preview_status_label, windows_leaf_name_error_korean,
};
#[cfg(all(test, not(windows)))]
pub(crate) use preview::{PreviewCounts, PreviewRowIssue};

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
pub(crate) const NATIVE_STATUS_COLUMN_WIDTH_DIP: i32 = 112;
#[cfg(any(windows, test))]
pub(crate) const EMPTY_LIST_STATUS: &str = "파일이나 폴더를 끌어 놓거나 Ctrl+O로 추가하세요.";
#[cfg(any(windows, test))]
pub(crate) const PREVIEW_SYNC_FAILURE_STATUS: &str =
    "미리보기를 표시하지 못해 적용을 잠갔습니다. 목록 작업을 다시 시도하거나 앱을 다시 시작하세요.";
#[cfg(windows)]
pub(crate) const PREVIEW_SYNC_BLOCK_MESSAGE: &str = "미리보기 표시가 동기화되지 않아 적용할 수 없습니다. 목록 작업을 다시 시도하거나 앱을 다시 시작하세요.";
#[cfg(windows)]
pub(crate) const EMPTY_STATE_INSTRUCTION: &str = "파일이나 폴더를 여기에 끌어오세요";
#[cfg(any(windows, test))]
pub(crate) const EMPTY_STATE_SAFETY: &str =
    "‘변경 적용’을 누르기 전에는 실제 파일을 수정하지 않습니다.";
#[cfg(any(windows, test))]
pub(crate) const EMPTY_STATE_SAFETY_RAILS: &str =
    "‘변경 적용’을 누르기 전에는\r\n실제 파일을 수정하지 않습니다.";
#[cfg(windows)]
pub(crate) const EMPTY_STATE_ADD_LABEL: &str = "파일 추가...";
#[cfg(windows)]
pub(crate) const DROP_ACCEPTING_TEXT: &str = "여기에 놓아 목록에 추가";
#[cfg(windows)]
pub(crate) const DROP_LOCKED_TEXT: &str = "현재 작업 중에는 추가할 수 없습니다.";
#[cfg(windows)]
pub(crate) const DROP_UNSUPPORTED_TEXT: &str = "파일 또는 폴더만 추가할 수 있습니다.";
#[cfg(windows)]
pub(crate) const DROP_FULL_TEXT: &str = "목록에 더 추가할 수 없습니다.";
#[cfg(windows)]
pub(crate) const STATUS_COUNT_SAMPLE: &str = "전체 10000 · 변경 10000 · 선택 10000";
#[cfg(windows)]
pub(crate) const STATUS_CANCEL_LABEL: &str = "취소";

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HorizontalWindowPlacement {
    pub(crate) x: i32,
    pub(crate) width: i32,
}

/// Effective top-level minimum size after applying the nearest monitor bounds.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct WindowTrackSize {
    pub(crate) width: i32,
    pub(crate) height: i32,
}

/// Constrains a requested top-level minimum size to a positive monitor work area.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn constrain_minimum_track_size_to_work_area(
    minimum_width: i32,
    minimum_height: i32,
    work_width: i32,
    work_height: i32,
) -> Option<WindowTrackSize> {
    if minimum_width <= 0 || minimum_height <= 0 || work_width <= 0 || work_height <= 0 {
        return None;
    }
    Some(WindowTrackSize {
        width: minimum_width.min(work_width),
        height: minimum_height.min(work_height),
    })
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

/// Persisted application theme preference.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum AppThemeMode {
    #[default]
    System,
    Light,
    Dark,
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

/// Persisted strength of proposed-name semantic emphasis.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum PreviewEmphasis {
    Subtle,
    #[default]
    Standard,
    Strong,
}

/// User-owned appearance preferences stored independently from column state.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct UiAppearance {
    pub(crate) theme: AppThemeMode,
    pub(crate) density: RailDensityPreference,
    pub(crate) emphasis: PreviewEmphasis,
    pub(crate) show_separators: bool,
    pub(crate) show_preview_tint: bool,
    pub(crate) show_empty_safety: bool,
}

#[cfg(any(windows, test))]
impl Default for UiAppearance {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// Appearance after fail-closed Forced Colors precedence is applied.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ResolvedUiAppearance {
    pub(crate) appearance: UiAppearance,
    pub(crate) theme: ResolvedTheme,
    pub(crate) custom_colors_enabled: bool,
}

/// Theme resolved for app-owned surfaces after system and accessibility policy.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ResolvedTheme {
    NativeSystem,
    Light,
    Dark,
}

/// Resolves background theme from the official UISettings foreground color.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn theme_from_foreground(red: u8, green: u8, blue: u8) -> ResolvedTheme {
    let luminance = (red as u32) * 299 + (green as u32) * 587 + (blue as u32) * 114;
    if luminance >= 128_000 {
        ResolvedTheme::Dark
    } else {
        ResolvedTheme::Light
    }
}

/// Semantic colors for the small set of app-owned native surfaces.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct SemanticPalette {
    pub(crate) surface_window: u32,
    pub(crate) surface_panel: u32,
    pub(crate) surface_workspace: u32,
    pub(crate) surface_status: u32,
    pub(crate) surface_drop: u32,
    pub(crate) surface_header: u32,
    pub(crate) surface_dialog: u32,
    pub(crate) control_normal: u32,
    pub(crate) control_hover: u32,
    pub(crate) control_pressed: u32,
    pub(crate) control_disabled: u32,
    pub(crate) text_primary: u32,
    pub(crate) text_secondary: u32,
    pub(crate) text_disabled: u32,
    pub(crate) border: u32,
    pub(crate) changed_subtle: u32,
    pub(crate) changed_standard: u32,
    pub(crate) changed_strong: u32,
    pub(crate) warning: u32,
    pub(crate) collision: u32,
    pub(crate) preview_tint: u32,
    pub(crate) apply_keyline: u32,
}

#[cfg(any(windows, test))]
const fn color_ref(red: u8, green: u8, blue: u8) -> u32 {
    (red as u32) | ((green as u32) << 8) | ((blue as u32) << 16)
}

#[cfg(any(windows, test))]
const PRECISION_LIGHT: SemanticPalette = SemanticPalette {
    surface_window: color_ref(247, 248, 250),
    surface_panel: color_ref(247, 248, 250),
    surface_workspace: color_ref(255, 255, 255),
    surface_status: color_ref(244, 245, 247),
    surface_drop: color_ref(245, 248, 255),
    surface_header: color_ref(238, 240, 243),
    surface_dialog: color_ref(247, 248, 250),
    control_normal: color_ref(255, 255, 255),
    control_hover: color_ref(240, 244, 250),
    control_pressed: color_ref(226, 232, 240),
    control_disabled: color_ref(235, 237, 240),
    text_primary: color_ref(27, 29, 32),
    text_secondary: color_ref(95, 102, 112),
    text_disabled: color_ref(139, 145, 154),
    border: color_ref(177, 183, 192),
    changed_subtle: color_ref(121, 43, 51),
    changed_standard: color_ref(143, 38, 51),
    changed_strong: color_ref(169, 22, 33),
    warning: color_ref(142, 83, 0),
    collision: color_ref(169, 22, 33),
    preview_tint: color_ref(245, 248, 255),
    apply_keyline: color_ref(217, 41, 50),
};

#[cfg(any(windows, test))]
const GRAPHITE_DARK: SemanticPalette = SemanticPalette {
    surface_window: color_ref(20, 22, 25),
    surface_panel: color_ref(20, 22, 25),
    surface_workspace: color_ref(23, 25, 28),
    surface_status: color_ref(30, 32, 36),
    surface_drop: color_ref(32, 40, 51),
    surface_header: color_ref(38, 41, 46),
    surface_dialog: color_ref(26, 28, 32),
    control_normal: color_ref(42, 45, 50),
    control_hover: color_ref(52, 57, 64),
    control_pressed: color_ref(32, 35, 40),
    control_disabled: color_ref(34, 37, 41),
    text_primary: color_ref(242, 244, 247),
    text_secondary: color_ref(184, 190, 199),
    text_disabled: color_ref(125, 131, 140),
    border: color_ref(83, 89, 99),
    changed_subtle: color_ref(217, 164, 168),
    changed_standard: color_ref(255, 102, 112),
    changed_strong: color_ref(255, 137, 145),
    warning: color_ref(255, 194, 92),
    collision: color_ref(255, 137, 145),
    preview_tint: color_ref(32, 40, 51),
    apply_keyline: color_ref(255, 102, 112),
};

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn semantic_palette(theme: ResolvedTheme) -> Option<SemanticPalette> {
    match theme {
        ResolvedTheme::NativeSystem => None,
        ResolvedTheme::Light => Some(PRECISION_LIGHT),
        ResolvedTheme::Dark => Some(GRAPHITE_DARK),
    }
}

/// Whether one app-owned input prompt can install its custom palette atomically.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn prompt_custom_theme_enabled(
    resolved: ResolvedUiAppearance,
    resources_complete: bool,
    control_theme_complete: bool,
) -> bool {
    resolved.custom_colors_enabled
        && !matches!(resolved.theme, ResolvedTheme::NativeSystem)
        && resources_complete
        && control_theme_complete
}

/// Custom colors for one changed proposed-name cell.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ProposedNameColors {
    pub(crate) text: u32,
    pub(crate) background: Option<u32>,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn proposed_name_colors(
    resolved: ResolvedUiAppearance,
    visual: ProposedNameVisual,
) -> Option<ProposedNameColors> {
    if !resolved.custom_colors_enabled || matches!(visual, ProposedNameVisual::Default) {
        return None;
    }
    let Some(palette) = semantic_palette(resolved.theme) else {
        return None;
    };
    let text = match visual {
        ProposedNameVisual::Warning => palette.warning,
        ProposedNameVisual::Collision => palette.collision,
        ProposedNameVisual::Changed => match resolved.appearance.emphasis {
            PreviewEmphasis::Subtle => palette.changed_subtle,
            PreviewEmphasis::Standard => palette.changed_standard,
            PreviewEmphasis::Strong => palette.changed_strong,
        },
        ProposedNameVisual::Default => return None,
    };
    Some(ProposedNameColors {
        text,
        background: if resolved.appearance.show_preview_tint {
            Some(palette.preview_tint)
        } else {
            None
        },
    })
}

#[cfg(any(windows, test))]
impl UiAppearance {
    #[must_use]
    pub(crate) const fn resolve(
        self,
        forced_colors: ForcedColorsState,
        system_theme: Option<ResolvedTheme>,
    ) -> ResolvedUiAppearance {
        if !forced_colors.custom_colors_enabled() {
            return ResolvedUiAppearance {
                appearance: Self {
                    theme: AppThemeMode::System,
                    show_preview_tint: false,
                    ..self
                },
                theme: ResolvedTheme::NativeSystem,
                custom_colors_enabled: false,
            };
        }
        let (theme, custom_colors_enabled) = match self.theme {
            AppThemeMode::Light => (ResolvedTheme::Light, true),
            AppThemeMode::Dark => (ResolvedTheme::Dark, true),
            AppThemeMode::System => match system_theme {
                Some(ResolvedTheme::Dark) => (ResolvedTheme::Dark, true),
                Some(ResolvedTheme::Light) => (ResolvedTheme::Light, true),
                Some(ResolvedTheme::NativeSystem) | None => (ResolvedTheme::NativeSystem, false),
            },
        };
        ResolvedUiAppearance {
            appearance: self,
            theme,
            custom_colors_enabled,
        }
    }
}

/// Best-effort DWM frame update needed for one resolved transition.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DwmFrameAction {
    None,
    SetDark(bool),
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn dwm_frame_action(
    theme: ResolvedTheme,
    dark_frame_requested: bool,
) -> DwmFrameAction {
    match theme {
        ResolvedTheme::Dark => DwmFrameAction::SetDark(true),
        ResolvedTheme::Light => DwmFrameAction::SetDark(false),
        ResolvedTheme::NativeSystem if dark_frame_requested => DwmFrameAction::SetDark(false),
        ResolvedTheme::NativeSystem => DwmFrameAction::None,
    }
}

/// Auxiliary appearance commands stay outside the contiguous legacy catalog.
#[cfg(any(windows, test))]
pub(crate) const THEME_SYSTEM: u16 = 0x9010;
#[cfg(any(windows, test))]
pub(crate) const THEME_LIGHT: u16 = 0x9011;
#[cfg(any(windows, test))]
pub(crate) const THEME_DARK: u16 = 0x9012;
#[cfg(any(windows, test))]
pub(crate) const APPEARANCE_ADVANCED: u16 = 0x9013;

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn theme_mode_for_command(command: u16) -> Option<AppThemeMode> {
    match command {
        THEME_SYSTEM => Some(AppThemeMode::System),
        THEME_LIGHT => Some(AppThemeMode::Light),
        THEME_DARK => Some(AppThemeMode::Dark),
        _ => None,
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn theme_command_for_mode(mode: AppThemeMode) -> u16 {
    match mode {
        AppThemeMode::System => THEME_SYSTEM,
        AppThemeMode::Light => THEME_LIGHT,
        AppThemeMode::Dark => THEME_DARK,
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn appearance_command_allowed(command: u16, worker_active: bool) -> bool {
    theme_mode_for_command(command).is_some() || (command == APPEARANCE_ADVANCED && !worker_active)
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn appearance_after_theme_command(
    appearance: UiAppearance,
    command: u16,
) -> Option<UiAppearance> {
    let Some(theme) = theme_mode_for_command(command) else {
        return None;
    };
    Some(UiAppearance {
        theme,
        ..appearance
    })
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn advanced_appearance_available(
    worker_active: bool,
    confirmation_pending: bool,
) -> bool {
    !worker_active && !confirmation_pending
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn appearance_dialog_should_notify_cancel(armed: bool, finished: bool) -> bool {
    armed && !finished
}

/// Pure action understood by the dedicated advanced-appearance dialog.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AppearanceDialogAction {
    Density(RailDensityPreference),
    Emphasis(PreviewEmphasis),
    ShowSeparators(bool),
    ShowPreviewTint(bool),
    ShowEmptySafety(bool),
    ResetDefaults,
    Accept,
    Cancel,
}

/// Terminal or preview effect emitted by one appearance-dialog action.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum AppearanceDialogEffect {
    None,
    Preview(UiAppearance),
    Accept(UiAppearance),
    Cancel(UiAppearance),
}

/// Borrow-free appearance-dialog state used by native controls and tests.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct AppearanceDialogModel {
    original: UiAppearance,
    draft: UiAppearance,
    forced_colors: ForcedColorsState,
}

#[cfg(any(windows, test))]
impl AppearanceDialogModel {
    #[must_use]
    pub(crate) const fn new(original: UiAppearance, forced_colors: ForcedColorsState) -> Self {
        Self {
            original,
            draft: original,
            forced_colors,
        }
    }

    #[must_use]
    pub(crate) const fn draft(self) -> UiAppearance {
        self.draft
    }

    #[must_use]
    pub(crate) const fn forced_colors(self) -> ForcedColorsState {
        self.forced_colors
    }

    pub(crate) const fn set_forced_colors(&mut self, forced_colors: ForcedColorsState) {
        self.forced_colors = forced_colors;
    }

    pub(crate) fn apply(&mut self, action: AppearanceDialogAction) -> AppearanceDialogEffect {
        let next = match action {
            AppearanceDialogAction::Density(density) => UiAppearance {
                density,
                ..self.draft
            },
            AppearanceDialogAction::Emphasis(emphasis)
                if self.forced_colors.custom_colors_enabled() =>
            {
                UiAppearance {
                    emphasis,
                    ..self.draft
                }
            }
            AppearanceDialogAction::ShowSeparators(show_separators) => UiAppearance {
                show_separators,
                ..self.draft
            },
            AppearanceDialogAction::ShowPreviewTint(show_preview_tint)
                if self.forced_colors.custom_colors_enabled() =>
            {
                UiAppearance {
                    show_preview_tint,
                    ..self.draft
                }
            }
            AppearanceDialogAction::ShowEmptySafety(show_empty_safety) => UiAppearance {
                show_empty_safety,
                ..self.draft
            },
            AppearanceDialogAction::ResetDefaults => UiAppearance {
                theme: self.draft.theme,
                ..UiAppearance::DEFAULT
            },
            AppearanceDialogAction::Accept => return AppearanceDialogEffect::Accept(self.draft),
            AppearanceDialogAction::Cancel => {
                self.draft = self.original;
                return AppearanceDialogEffect::Cancel(self.original);
            }
            AppearanceDialogAction::Emphasis(_) | AppearanceDialogAction::ShowPreviewTint(_) => {
                self.draft
            }
        };
        if next == self.draft {
            AppearanceDialogEffect::None
        } else {
            self.draft = next;
            AppearanceDialogEffect::Preview(next)
        }
    }
}

#[cfg(any(windows, test))]
impl UiAppearance {
    pub(crate) const DEFAULT: Self = Self {
        theme: AppThemeMode::System,
        density: RailDensityPreference::Automatic,
        emphasis: PreviewEmphasis::Standard,
        show_separators: true,
        show_preview_tint: true,
        show_empty_safety: true,
    };
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn pack_ui_appearance(appearance: UiAppearance) -> u32 {
    let theme = match appearance.theme {
        AppThemeMode::System => 0,
        AppThemeMode::Light => 1,
        AppThemeMode::Dark => 2,
    };
    let density = match appearance.density {
        RailDensityPreference::Automatic => 0,
        RailDensityPreference::Comfortable => 1,
        RailDensityPreference::Compact => 2,
        RailDensityPreference::MenuOnly => 3,
    };
    let emphasis = match appearance.emphasis {
        PreviewEmphasis::Subtle => 0,
        PreviewEmphasis::Standard => 1,
        PreviewEmphasis::Strong => 2,
    };
    theme
        | (density << 2)
        | (emphasis << 4)
        | ((appearance.show_separators as u32) << 6)
        | ((appearance.show_preview_tint as u32) << 7)
        | ((appearance.show_empty_safety as u32) << 8)
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn unpack_ui_appearance(packed: u32) -> Option<UiAppearance> {
    if packed & !0x1FF != 0 {
        return None;
    }
    let theme = match packed & 0x3 {
        0 => AppThemeMode::System,
        1 => AppThemeMode::Light,
        2 => AppThemeMode::Dark,
        _ => return None,
    };
    let density = match (packed >> 2) & 0x3 {
        0 => RailDensityPreference::Automatic,
        1 => RailDensityPreference::Comfortable,
        2 => RailDensityPreference::Compact,
        3 => RailDensityPreference::MenuOnly,
        _ => return None,
    };
    let emphasis = match (packed >> 4) & 0x3 {
        0 => PreviewEmphasis::Subtle,
        1 => PreviewEmphasis::Standard,
        2 => PreviewEmphasis::Strong,
        _ => return None,
    };
    Some(UiAppearance {
        theme,
        density,
        emphasis,
        show_separators: packed & (1 << 6) != 0,
        show_preview_tint: packed & (1 << 7) != 0,
        show_empty_safety: packed & (1 << 8) != 0,
    })
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

/// Text extents measured from the active native message and status fonts.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct MeasuredFontMetrics {
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

    fn empty_state_content_metrics(
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
    }
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct EmptyStateContentMetrics {
    instruction_height: i32,
    safety_height: i32,
    add_width: i32,
    add_height: i32,
    total_height: i32,
}

#[cfg(any(windows, test))]
fn conservative_wrapped_text_height(
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

/// Major focus regions in the native workbench.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum FocusChild {
    #[default]
    List,
    LeftRail,
    RightRail,
}

/// Borrow-free focus action selected by the platform-neutral state machine.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FocusAction {
    List,
    LeftRail(usize),
    RightRail(usize),
}

/// Platform-neutral state for roving focus within the two command rails.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct FocusState {
    pub(crate) last_child: FocusChild,
    pub(crate) left_rail_index: usize,
    pub(crate) right_rail_index: usize,
}

#[cfg(any(windows, test))]
impl FocusState {
    pub(crate) const fn action(self) -> FocusAction {
        match self.last_child {
            FocusChild::List => FocusAction::List,
            FocusChild::LeftRail => FocusAction::LeftRail(self.left_rail_index),
            FocusChild::RightRail => FocusAction::RightRail(self.right_rail_index),
        }
    }

    pub(crate) fn record(&mut self, child: FocusChild, rail_index: Option<usize>) {
        self.last_child = child;
        match (child, rail_index) {
            (FocusChild::LeftRail, Some(index)) => self.left_rail_index = index,
            (FocusChild::RightRail, Some(index)) => self.right_rail_index = index,
            _ => {}
        }
    }

    pub(crate) fn repair(
        &mut self,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) {
        let left = rails_visible
            .then(|| repair_focus_index(self.left_rail_index, left_enabled))
            .flatten();
        let right = rails_visible
            .then(|| repair_focus_index(self.right_rail_index, right_enabled))
            .flatten();
        if let Some(index) = left {
            self.left_rail_index = index;
        }
        if let Some(index) = right {
            self.right_rail_index = index;
        }
        if matches!(self.last_child, FocusChild::LeftRail) && left.is_none()
            || matches!(self.last_child, FocusChild::RightRail) && right.is_none()
        {
            self.last_child = FocusChild::List;
        }
    }

    pub(crate) fn cycle_major(
        &mut self,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) -> FocusChild {
        self.repair(left_enabled, right_enabled, rails_visible);
        let available = |child| match child {
            FocusChild::List => true,
            FocusChild::LeftRail => rails_visible && left_enabled.iter().any(|enabled| *enabled),
            FocusChild::RightRail => rails_visible && right_enabled.iter().any(|enabled| *enabled),
        };
        let regions = [
            FocusChild::List,
            FocusChild::LeftRail,
            FocusChild::RightRail,
        ];
        let start = regions
            .iter()
            .position(|child| *child == self.last_child)
            .unwrap_or_default();
        for offset in 1..=regions.len() {
            let child = regions[(start + offset) % regions.len()];
            if available(child) {
                self.last_child = child;
                return child;
            }
        }
        self.last_child = FocusChild::List;
        FocusChild::List
    }

    pub(crate) fn move_within_rail(
        &mut self,
        forward: bool,
        left_enabled: &[bool],
        right_enabled: &[bool],
        rails_visible: bool,
    ) -> Option<(FocusChild, usize)> {
        self.repair(left_enabled, right_enabled, rails_visible);
        let (enabled, current) = match self.last_child {
            FocusChild::List => return None,
            FocusChild::LeftRail => (left_enabled, &mut self.left_rail_index),
            FocusChild::RightRail => (right_enabled, &mut self.right_rail_index),
        };
        let next = adjacent_enabled_index(*current, enabled, forward)?;
        *current = next;
        Some((self.last_child, next))
    }

    pub(crate) fn active_index(
        self,
        child: FocusChild,
        enabled: &[bool],
        rails_visible: bool,
    ) -> Option<usize> {
        if !rails_visible {
            return None;
        }
        let index = match child {
            FocusChild::List => return None,
            FocusChild::LeftRail => self.left_rail_index,
            FocusChild::RightRail => self.right_rail_index,
        };
        enabled
            .get(index)
            .copied()
            .unwrap_or(false)
            .then_some(index)
    }
}

/// Native ComboBox operation whose sentinel return value must be checked.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ComboOperation {
    AddString,
    Select,
}

/// Normalized native ComboBox failure, independent of Win32 bindings.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ComboControlError {
    Rejected,
    OutOfSpace,
}

#[cfg(any(windows, test))]
pub(crate) const fn validate_combo_result(
    operation: ComboOperation,
    result: isize,
) -> Result<(), ComboControlError> {
    match (operation, result) {
        (ComboOperation::AddString, -2) => Err(ComboControlError::OutOfSpace),
        (ComboOperation::AddString | ComboOperation::Select, -1) => {
            Err(ComboControlError::Rejected)
        }
        _ => Ok(()),
    }
}

#[cfg(any(windows, test))]
fn repair_focus_index(current: usize, enabled: &[bool]) -> Option<usize> {
    enabled
        .get(current)
        .copied()
        .unwrap_or(false)
        .then_some(current)
        .or_else(|| enabled.iter().position(|enabled| *enabled))
}

#[cfg(any(windows, test))]
fn adjacent_enabled_index(current: usize, enabled: &[bool], forward: bool) -> Option<usize> {
    if enabled.is_empty() || !enabled.iter().any(|enabled| *enabled) {
        return None;
    }
    for offset in 1..=enabled.len() {
        let index = if forward {
            current.wrapping_add(offset) % enabled.len()
        } else {
            current.wrapping_add(enabled.len()).wrapping_sub(offset) % enabled.len()
        };
        if enabled[index] {
            return Some(index);
        }
    }
    None
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
    let mut index = 0_usize;
    while index < COMMAND_UI_SPECS.len() {
        let spec = COMMAND_UI_SPECS[index];
        if spec.id == command {
            return spec.rail.map(|placement| placement.group);
        }
        index += 1;
    }
    None
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

/// Directory admission selected by the three-way native prompt.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DirectoryPromptChoice {
    Direct,
    Recurse,
    Cancel,
}

#[cfg(any(windows, test))]
pub(crate) const DIRECTORY_DIRECT_BUTTON_ID: i32 = 1_001;
#[cfg(any(windows, test))]
pub(crate) const DIRECTORY_RECURSE_BUTTON_ID: i32 = 1_002;
#[cfg(any(windows, test))]
pub(crate) const APPLY_CONFIRM_BUTTON_ID: i32 = 1_101;
#[cfg(any(windows, test))]
pub(crate) const DISCARD_CONFIRM_BUTTON_ID: i32 = 1_201;
#[cfg(any(windows, test))]
pub(crate) const RECOVER_CONFIRM_BUTTON_ID: i32 = 1_202;

/// Maps native task-dialog response values, failing closed for every unknown result.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn directory_prompt_choice(result: i32) -> DirectoryPromptChoice {
    match result {
        DIRECTORY_DIRECT_BUTTON_ID => DirectoryPromptChoice::Direct,
        DIRECTORY_RECURSE_BUTTON_ID => DirectoryPromptChoice::Recurse,
        _ => DirectoryPromptChoice::Cancel,
    }
}

/// Decision for a destructive custom-button task dialog.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DestructivePromptChoice {
    Confirm,
    Cancel,
}

/// Accepts only the exact custom affirmative button and cancels every other result.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn destructive_prompt_choice(
    result: i32,
    confirm_button_id: i32,
) -> DestructivePromptChoice {
    if result == confirm_button_id {
        DestructivePromptChoice::Confirm
    } else {
        DestructivePromptChoice::Cancel
    }
}

/// Non-authorizing counts shown before an exact rename plan is confirmed.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ApplyConfirmationSummary {
    logical_changed: usize,
    rename_only: usize,
    move_only: usize,
    move_and_rename: usize,
    common_destination_parent: Option<darknamer_core::LegacyText>,
    case_only: usize,
    temporary_groups: usize,
    primitive_steps: usize,
}

#[cfg(any(windows, test))]
impl ApplyConfirmationSummary {
    /// Summarizes one immutable plan using the backend's exact path-equivalence rule.
    #[must_use]
    pub(crate) fn from_plan(
        plan: &crate::rename::RenamePlan,
        primitive_steps: usize,
        mut paths_equivalent: impl FnMut(
            &darknamer_core::LegacyText,
            &darknamer_core::LegacyText,
        ) -> bool,
    ) -> Option<Self> {
        let mut rename_only = 0;
        let mut move_only = 0;
        let mut move_and_rename = 0;
        let mut case_only = 0;
        let mut common_destination_parent = None;
        let mut destination_parents_match = true;
        for row in plan.rows() {
            let (source_parent, source_leaf) = split_windows_path(row.source());
            let (destination_parent, destination_leaf) = split_windows_path(row.destination());
            let source_parent = darknamer_core::LegacyText::from_units(source_parent.to_vec());
            let destination_parent =
                darknamer_core::LegacyText::from_units(destination_parent.to_vec());
            let moved = !paths_equivalent(&source_parent, &destination_parent);
            let renamed = source_leaf != destination_leaf;
            match (moved, renamed) {
                (false, true) => rename_only += 1,
                (true, false) => move_only += 1,
                (true, true) => move_and_rename += 1,
                (false, false) => return None,
            }
            if paths_equivalent(row.source(), row.destination()) {
                case_only += 1;
            }
            match &common_destination_parent {
                None => common_destination_parent = Some(destination_parent),
                Some(common) if common == &destination_parent => {}
                Some(_) => destination_parents_match = false,
            }
        }
        if !destination_parents_match {
            common_destination_parent = None;
        }
        Self::from_counts(
            rename_only,
            move_only,
            move_and_rename,
            common_destination_parent,
            case_only,
            primitive_steps,
        )
    }

    /// Builds a summary only when the scheduler counts are internally consistent.
    #[must_use]
    pub(crate) fn from_counts(
        rename_only: usize,
        move_only: usize,
        move_and_rename: usize,
        common_destination_parent: Option<darknamer_core::LegacyText>,
        case_only: usize,
        primitive_steps: usize,
    ) -> Option<Self> {
        let logical_changed = rename_only
            .checked_add(move_only)?
            .checked_add(move_and_rename)?;
        if case_only > logical_changed || primitive_steps < logical_changed {
            return None;
        }
        Some(Self {
            logical_changed,
            rename_only,
            move_only,
            move_and_rename,
            common_destination_parent,
            case_only,
            temporary_groups: primitive_steps - logical_changed,
            primitive_steps,
        })
    }

    #[must_use]
    pub(crate) const fn logical_changed(&self) -> usize {
        self.logical_changed
    }

    #[must_use]
    pub(crate) const fn case_only(&self) -> usize {
        self.case_only
    }

    #[must_use]
    pub(crate) const fn cycle_groups(&self) -> usize {
        self.temporary_groups.saturating_sub(self.case_only)
    }

    #[must_use]
    pub(crate) const fn primitive_steps(&self) -> usize {
        self.primitive_steps
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn apply_confirmation_primary(summary: ApplyConfirmationSummary) -> String {
    let mut text = format!(
        "논리적 변경: {}개\n이름만 변경: {}개\n이동만: {}개\n이동 및 이름 변경: {}개\n대소문자만 변경: {}개\n순환 변경 그룹: {}개\n파일 시스템 변경 단계: {}개",
        summary.logical_changed(),
        summary.rename_only,
        summary.move_only,
        summary.move_and_rename,
        summary.case_only(),
        summary.cycle_groups(),
        summary.primitive_steps(),
    );
    if let Some(parent) = summary.common_destination_parent {
        text.push_str("\n대상 폴더: ");
        text.push_str(&parent.to_string_lossy());
    }
    text.push_str("\n대상 덮어쓰기: 허용하지 않음");
    text
}

#[cfg(any(windows, test))]
fn split_windows_path(path: &darknamer_core::LegacyText) -> (&[u16], &[u16]) {
    let split = path
        .units()
        .iter()
        .rposition(|unit| *unit == u16::from(b'\\') || *unit == u16::from(b'/'));
    split.map_or((&[], path.units()), |index| {
        let parent_end = if index > 0 && path.units()[index - 1] == u16::from(b':') {
            index + 1
        } else {
            index
        };
        (&path.units()[..parent_end], &path.units()[index + 1..])
    })
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn apply_confirmation_detail(fingerprint: u64, revision: u64) -> String {
    format!("계획 지문: {fingerprint:016X}\n목록 버전: {revision}")
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
fn calculate_drop_overlay_layout(
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
struct EmptyStateLayout {
    instruction: LayoutRect,
    safety: LayoutRect,
    add: LayoutRect,
}

#[cfg(any(windows, test))]
#[must_use]
fn calculate_empty_state_layout(
    list: LayoutRect,
    dpi: u32,
    measured: MeasuredFontMetrics,
    show_safety: bool,
) -> EmptyStateLayout {
    let horizontal_padding = scale_dip(12, dpi).min(list.width.saturating_div(2));
    let content_width = list
        .width
        .saturating_sub(horizontal_padding.saturating_mul(2));
    let content = measured.empty_state_content_metrics(dpi, content_width, show_safety);
    let desired_instruction_height = content.instruction_height;
    let desired_button_height = content.add_height;
    let desired_safety_height = content.safety_height;
    let desired_gap = scale_dip(8, dpi);
    let desired_total = content.total_height;
    let top = list
        .y
        .saturating_add(list.height.saturating_sub(desired_total).max(0) / 2);
    let bottom = list.bottom();
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
            x: list.x.saturating_add(horizontal_padding),
            y: instruction_y,
            width: content_width,
            height: instruction_height,
        },
        safety: LayoutRect {
            x: list.x.saturating_add(horizontal_padding),
            y: safety_y,
            width: content_width,
            height: safety_height,
        },
        add: LayoutRect {
            x: list
                .x
                .saturating_add(list.width.saturating_sub(button_width) / 2),
            y: button_y,
            width: button_width,
            height: button_height,
        },
    }
}

/// Visual readiness of the filesystem Apply command.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ApplyPresentation {
    NoChanges,
    Ready,
    Blocked,
    Working,
}

/// Visibility state for the empty-list onboarding controls.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum EmptyStatePresentation {
    Hidden,
    ReadyToAdd,
    Unavailable,
}

/// Immediate OLE drag feedback. Accepting advertises eligibility, not admission
/// success and never authorizes a worker or filesystem mutation.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum DropPresentation {
    #[default]
    Inactive,
    Accepting,
    Locked,
    Unsupported,
    Full,
}

#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct DropNegotiation {
    pub(crate) presentation: DropPresentation,
    pub(crate) effect: u32,
}

#[cfg(any(windows, test))]
pub(crate) const DROP_EFFECT_NONE: u32 = 0;
#[cfg(any(windows, test))]
pub(crate) const DROP_EFFECT_COPY: u32 = 1;

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn drop_effect_after_admission_start(started: bool) -> u32 {
    if started {
        DROP_EFFECT_COPY
    } else {
        DROP_EFFECT_NONE
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn negotiate_drop_effect(
    format_supported: bool,
    ui_locked: bool,
    remaining_capacity: usize,
    source_effects: u32,
) -> DropNegotiation {
    if !format_supported || source_effects & DROP_EFFECT_COPY == 0 {
        DropNegotiation {
            presentation: DropPresentation::Unsupported,
            effect: DROP_EFFECT_NONE,
        }
    } else if remaining_capacity == 0 {
        DropNegotiation {
            presentation: DropPresentation::Full,
            effect: DROP_EFFECT_NONE,
        }
    } else if ui_locked {
        DropNegotiation {
            presentation: DropPresentation::Locked,
            effect: DROP_EFFECT_NONE,
        }
    } else {
        DropNegotiation {
            presentation: DropPresentation::Accepting,
            effect: DROP_EFFECT_COPY,
        }
    }
}

/// Existing authorization boundaries supplied to the pure presentation model.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct PresentationLocks {
    pub(crate) apply_locked: bool,
    pub(crate) empty_locked: bool,
    pub(crate) worker_active: bool,
}

/// Whether the native preview is known to represent the current model.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum PreviewSynchronization {
    #[default]
    Pending,
    Synchronized,
    Failed,
}

#[cfg(any(windows, test))]
impl PreviewSynchronization {
    #[must_use]
    pub(crate) const fn is_synchronized(self) -> bool {
        matches!(self, Self::Synchronized)
    }

    pub(crate) fn mark_synchronized(&mut self) {
        *self = Self::Synchronized;
    }

    pub(crate) fn mark_failed(&mut self) {
        *self = Self::Failed;
    }
}

/// Pure native workbench presentation derived from model, selection, and locks.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct UiPresentation {
    pub(crate) counts: PreviewCounts,
    pub(crate) apply: ApplyPresentation,
    pub(crate) empty: EmptyStatePresentation,
}

#[cfg(any(windows, test))]
impl UiPresentation {
    #[must_use]
    pub(crate) const fn derive(counts: PreviewCounts, locks: PresentationLocks) -> Self {
        let apply = if locks.worker_active {
            ApplyPresentation::Working
        } else if counts.changed == 0 {
            ApplyPresentation::NoChanges
        } else if locks.apply_locked {
            ApplyPresentation::Blocked
        } else {
            ApplyPresentation::Ready
        };
        let empty = if counts.total != 0 {
            EmptyStatePresentation::Hidden
        } else if locks.empty_locked || locks.worker_active {
            EmptyStatePresentation::Unavailable
        } else {
            EmptyStatePresentation::ReadyToAdd
        };
        Self {
            counts,
            apply,
            empty,
        }
    }
}

/// Proposed-name cell styling selected without replacing native drawing.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ProposedNameVisual {
    Default,
    Changed,
    Warning,
    Collision,
}

/// Cached forced-colors state. Unknown queries fail closed like active mode.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum ForcedColorsState {
    Inactive,
    #[default]
    ActiveOrUnknown,
}

#[cfg(any(windows, test))]
impl ForcedColorsState {
    #[must_use]
    pub(crate) const fn from_high_contrast_query(active: Option<bool>) -> Self {
        if matches!(active, Some(false)) {
            Self::Inactive
        } else {
            Self::ActiveOrUnknown
        }
    }

    #[must_use]
    pub(crate) const fn custom_colors_enabled(self) -> bool {
        matches!(self, Self::Inactive)
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn apply_readiness_indicator_visible(
    apply: ApplyPresentation,
    forced_colors: ForcedColorsState,
    rails_visible: bool,
) -> bool {
    rails_visible
        && matches!(apply, ApplyPresentation::Ready)
        && forced_colors.custom_colors_enabled()
}

/// Inputs whose precedence decides whether one proposed-name cell is accented.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ProposedNameVisualContext {
    pub(crate) row: Option<usize>,
    pub(crate) row_count: usize,
    pub(crate) subitem: i32,
    pub(crate) changed: bool,
    pub(crate) issue: PreviewRowIssue,
    pub(crate) selected: bool,
    pub(crate) focused: bool,
    pub(crate) custom_colors_enabled: bool,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn proposed_name_visual_decision(
    context: ProposedNameVisualContext,
) -> ProposedNameVisual {
    let valid_row = match context.row {
        Some(row) => row < context.row_count,
        None => false,
    };
    if context.subitem == 1
        && valid_row
        && context.changed
        && !context.selected
        && context.custom_colors_enabled
    {
        match context.issue {
            PreviewRowIssue::None => ProposedNameVisual::Changed,
            PreviewRowIssue::EmptyStem => ProposedNameVisual::Warning,
            PreviewRowIssue::InvalidName(_) => ProposedNameVisual::Collision,
            PreviewRowIssue::DuplicateDestination => ProposedNameVisual::Collision,
        }
    } else {
        ProposedNameVisual::Default
    }
}

/// Structured status content whose independent channels survive row refreshes.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct UiStatus {
    counts: PreviewCounts,
    transient: Option<String>,
    progress: Option<String>,
    recovery: Option<String>,
    preview_sync_failed: bool,
    preview_notice: Option<String>,
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

    pub(crate) fn set_preview_counts(&mut self, counts: PreviewCounts) {
        self.counts = counts;
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

    pub(crate) fn set_preview_sync_failed(&mut self, failed: bool) {
        self.preview_sync_failed = failed;
    }

    pub(crate) fn set_preview_notice(&mut self, notice: Option<String>) {
        self.preview_notice = notice;
    }

    #[must_use]
    pub(crate) fn message_text(&self) -> &str {
        self.recovery
            .as_deref()
            .or(self.progress.as_deref())
            .or(self
                .preview_sync_failed
                .then_some(PREVIEW_SYNC_FAILURE_STATUS))
            .or(self.preview_notice.as_deref())
            .or(self.transient.as_deref())
            .unwrap_or(EMPTY_LIST_STATUS)
    }

    #[must_use]
    pub(crate) fn count_text(&self) -> String {
        format!(
            "전체 {} · 변경 {} · 선택 {}",
            self.counts.total, self.counts.changed, self.counts.selected
        )
    }
}

/// Current native worker activity used to derive the explicit Cancel control.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct WorkerActivity {
    pub(crate) admission: bool,
    pub(crate) plan: bool,
    pub(crate) apply: bool,
    pub(crate) cancellation_requested: bool,
}

/// The single worker whose existing cancellation primitive may be requested.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ActiveWorkerKind {
    Admission,
    Plan,
    Apply,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn active_worker_kind(activity: WorkerActivity) -> Option<ActiveWorkerKind> {
    match (activity.admission, activity.plan, activity.apply) {
        (true, false, false) => Some(ActiveWorkerKind::Admission),
        (false, true, false) => Some(ActiveWorkerKind::Plan),
        (false, false, true) => Some(ActiveWorkerKind::Apply),
        _ => None,
    }
}

/// Visibility and enabled state of the explicit worker Cancel control.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CancelControlState {
    Hidden,
    Enabled,
    Requested,
}

#[cfg(any(windows, test))]
impl CancelControlState {
    #[must_use]
    pub(crate) const fn is_visible(self) -> bool {
        !matches!(self, Self::Hidden)
    }

    #[must_use]
    pub(crate) const fn is_enabled(self) -> bool {
        matches!(self, Self::Enabled)
    }
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn cancel_control_state(activity: WorkerActivity) -> CancelControlState {
    if active_worker_kind(activity).is_none() {
        CancelControlState::Hidden
    } else if activity.cancellation_requested {
        CancelControlState::Requested
    } else {
        CancelControlState::Enabled
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
#[must_use]
pub(crate) fn status_column_width_after_resize(
    requested_width_px: i32,
    measured_minimum_px: i32,
    dpi: u32,
) -> i32 {
    unscale_px(requested_width_px.max(measured_minimum_px), dpi).max(NATIVE_STATUS_COLUMN_WIDTH_DIP)
}

#[cfg(any(windows, test))]
#[path = "windows/preferences.rs"]
mod preferences;

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
    let optional_width = columns[3..]
        .iter()
        .filter(|column| column.visible)
        .map(|column| column.width_px(dpi))
        .fold(0_i32, i32::saturating_add);
    let budget = client_width
        .max(0)
        .saturating_sub(status_width.max(0))
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
        + NATIVE_STATUS_COLUMN_WIDTH_DIP
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
/// Restores proposed destination parents without changing proposed names.
pub const RESET_PATH: CommandId = 0x8025;
pub const LAST_COMMAND: CommandId = RESET_PATH;
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
pub const COMMAND_UI_SPECS: [CommandUiSpec; 35] = [
    command_ui_spec!(
        APPLY,
        rail(RailSide::Left, 0, 0),
        "변경\n적용",
        menu(MenuGroup::File, 1, 0),
        "변경 사항 적용",
        "미리 본 이름 및 대상 폴더 변경을 실제 파일에 적용합니다.",
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
        "찾아\n바꾸기",
        menu(MenuGroup::Tools, 0, 0),
        "문자열 찾아 바꾸기...",
        "파일 이름에서 문자열을 찾아 다른 문자열로 바꿉니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PREFIX,
        rail(RailSide::Left, 1, 1),
        "앞에\n붙이기",
        menu(MenuGroup::Tools, 0, 1),
        "이름 앞에 문자열 붙이기...",
        "파일 이름 앞에 입력한 문자열을 붙입니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SUFFIX,
        rail(RailSide::Left, 1, 2),
        "뒤에\n붙이기",
        menu(MenuGroup::Tools, 0, 2),
        "이름 뒤에 문자열 붙이기...",
        "확장자 앞의 파일 이름 뒤에 입력한 문자열을 붙입니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_NAME,
        rail(RailSide::Left, 2, 0),
        "이름 본체\n지우기",
        menu(MenuGroup::Tools, 1, 0),
        "이름 본체 지우기",
        "확장자는 유지하고 파일 이름 본체를 지웁니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_POSITION,
        rail(RailSide::Left, 2, 1),
        "범위\n지우기",
        menu(MenuGroup::Tools, 1, 1),
        "지정 위치 범위 지우기...",
        "파일 이름의 지정한 위치 범위를 지웁니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_DELIMITED,
        rail(RailSide::Left, 2, 2),
        "사이\n지우기",
        menu(MenuGroup::Tools, 1, 2),
        "구분자 사이 지우기...",
        "파일 이름에서 지정한 두 구분자와 그 사이를 지웁니다.",
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
        "이름 본체에 숫자만 남기기",
        "확장자는 유지하고 파일 이름 본체에 ASCII 숫자만 남깁니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PAD_DIGITS,
        rail(RailSide::Left, 3, 1),
        "자릿수\n맞추기",
        menu(MenuGroup::Tools, 2, 1),
        "숫자 자릿수 맞추기...",
        "파일 이름에 있는 숫자의 자릿수를 0으로 맞춥니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SEQUENCE,
        rail(RailSide::Left, 3, 2),
        "일련번호\n붙이기",
        menu(MenuGroup::Tools, 2, 2),
        "일련번호 붙이기...",
        "목록 순서에 따라 파일 이름에 일련번호를 붙입니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        RESET,
        rail(RailSide::Right, 0, 0),
        "이름\n초기화",
        menu(MenuGroup::File, 1, 1),
        "모든 이름 변경 취소",
        "모든 제안 이름을 현재 이름으로 되돌립니다. 대상 폴더 변경은 유지됩니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_LIST,
        rail(RailSide::Right, 1, 0),
        "목록\n지우기",
        menu(MenuGroup::File, 1, 2),
        "목록 비우기",
        "목록에서 모든 항목을 제거합니다. 실제 파일은 삭제하지 않습니다.",
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
        "선택 항목 이름 직접 변경...",
        "선택한 한 항목의 제안 이름을 직접 변경합니다.",
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
        "목록 정렬...",
        "선택한 기준으로 목록 순서를 정렬합니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_PREFIX,
        rail(RailSide::Right, 2, 0),
        "폴더명\n앞에",
        menu(MenuGroup::Tools, 4, 0),
        "대상 폴더명을 이름 앞에 붙이기",
        "제안된 대상 폴더의 마지막 이름을 밑줄과 함께 파일 이름 앞에 붙입니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_SUFFIX,
        rail(RailSide::Right, 2, 1),
        "폴더명\n뒤에",
        menu(MenuGroup::Tools, 4, 1),
        "대상 폴더명을 이름 뒤에 붙이기",
        "제안된 대상 폴더의 마지막 이름을 밑줄과 함께 파일 이름 뒤에 붙입니다.",
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
        "모든 파일의 대상 폴더 지정...",
        "목록의 모든 일반 파일을 선택한 기존 폴더로 이동하도록 예약합니다. 적용 전에는 실제 파일을 이동하지 않습니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_DELETE,
        rail(RailSide::Right, 3, 0),
        "확장자\n지우기",
        menu(MenuGroup::Tools, 3, 0),
        "확장자 지우기",
        "파일 이름의 확장자를 지웁니다.",
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
        "확장자 추가...",
        "파일 이름에 확장자를 추가합니다.",
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
        "확장자 변경...",
        "파일 이름의 확장자를 바꿉니다.",
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
        "파일 추가...",
        "파일 선택기를 열어 목록에 파일을 추가합니다.",
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
        "변경 후 이름 목록 복사",
        "모든 항목의 변경 후 이름을 클립보드에 복사합니다.",
        None,
        Rows,
        None,
        NoRows
    ),
    command_ui_spec!(
        SAVE_NAMES,
        None,
        "이름 저장",
        menu(MenuGroup::File, 2, 1),
        "변경 후 이름 목록 저장...",
        "모든 항목의 변경 후 이름을 텍스트 파일로 저장합니다.",
        None,
        Rows,
        Filesystem,
        NoRows
    ),
    command_ui_spec!(
        COPY_PATHS,
        None,
        "경로 복사",
        menu(MenuGroup::File, 3, 0),
        "현재 경로 목록 복사",
        "모든 항목의 현재 실제 경로를 클립보드에 복사합니다.",
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
        "현재 경로 목록 저장...",
        "모든 항목의 현재 실제 경로를 텍스트 파일로 저장합니다.",
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
        "변경 후 이름 목록 가져오기...",
        "텍스트 파일의 이름을 목록 순서대로 변경 후 이름으로 가져옵니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        IMPORT_PATHS,
        None,
        "경로 불러오기",
        menu(MenuGroup::File, 4, 1),
        "경로 목록에서 추가...",
        "텍스트 파일에 적힌 현재 경로의 항목을 목록에 추가합니다.",
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
        "목록 순서 위로",
        "선택 항목을 목록 순서에서 한 칸 위로 이동합니다.",
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
        "목록 순서 아래로",
        "선택 항목을 목록 순서에서 한 칸 아래로 이동합니다.",
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
        "현재 전체 경로",
        "현재 실제 원본의 전체 경로 열을 표시합니다.",
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
        "파일 크기",
        "파일 크기 열을 표시합니다.",
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
        "수정 시각",
        "파일 수정 시각 열을 표시합니다.",
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
        "생성 시각",
        "파일 생성 시각 열을 표시합니다.",
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
        "DarkReNamer 정보...",
        "DarkReNamer 버전 및 저작권 정보를 표시합니다.",
        None,
        Always,
        None,
        NoRows
    ),
    command_ui_spec!(
        RESET_PATH,
        None,
        "원래 위치로",
        menu(MenuGroup::Tools, 4, 3),
        "대상 폴더 변경 취소",
        "각 파일의 대상 폴더를 현재 폴더로 되돌립니다. 제안 이름은 유지됩니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
];

/// Legacy shell accelerators whose commands are outside APPLY..LAST_COMMAND.
pub const LEGACY_AUXILIARY_SHORTCUTS: [LegacyCommandShortcut; 1] = [LegacyCommandShortcut {
    command: DELETE_SELECTED_COMMAND,
    shortcut: LegacyShortcut {
        virtual_key: LegacyVirtualKey::Delete,
        modifiers: LegacyShortcutModifiers::None,
        display: "Delete",
    },
}];

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
    RowsChanged(Box<[usize]>),
    ProposalRowsChanged(Box<[usize]>),
    AllRowsChanged,
    ColumnsChanged(usize),
    AppearanceChanged,
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
        UiEffect::RowsChanged(_) => command_ui_policy(command) == CommandUiPolicy::MovedRows,
        UiEffect::ProposalRowsChanged(_) => matches!(
            command_ui_policy(command),
            CommandUiPolicy::SingleRow | CommandUiPolicy::AllRows
        ),
        UiEffect::AllRowsChanged => command_ui_policy(command) == CommandUiPolicy::AllRows,
        UiEffect::ColumnsChanged(_) => command_ui_policy(command) == CommandUiPolicy::Columns,
        UiEffect::AppearanceChanged => appearance_command_allowed(command, false),
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

/// Pure work plan for updating only the proposal projection of rendered rows.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct ProposalRefreshPlan {
    pub(crate) rows: Box<[usize]>,
    pub(crate) proposal_cells: usize,
    pub(crate) immutable_cells: usize,
    pub(crate) full_row_formats: usize,
}

/// Validates and normalizes an exact proposal-row change set.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn proposal_refresh_plan(
    model_rows: usize,
    rendered_rows: usize,
    changed: &[usize],
) -> Option<ProposalRefreshPlan> {
    if model_rows != rendered_rows || changed.iter().any(|row| *row >= model_rows) {
        return None;
    }
    let mut rows = changed.to_vec();
    rows.sort_unstable();
    rows.dedup();
    let proposal_cells = rows.len();
    Some(ProposalRefreshPlan {
        rows: rows.into_boxed_slice(),
        proposal_cells,
        immutable_cells: 0,
        full_row_formats: 0,
    })
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
#[allow(
    unsafe_code,
    reason = "the native Win32 UI boundary audits raw handles, callback pointers, and FFI lifetimes"
)]
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
            RESET_PATH,
        ];
        assert_eq!(ids, core::array::from_fn(|index| 0x8003 + index as u16));
    }

    #[test]
    fn command_catalog_is_complete_unique_and_resource_ordered() {
        assert_eq!(
            COMMAND_UI_SPECS.len(),
            usize::from(LAST_COMMAND - APPLY + 1)
        );
        assert_eq!(
            COMMAND_UI_SPECS.map(|spec| spec.id),
            core::array::from_fn(|index| APPLY + index as u16)
        );
        for spec in &COMMAND_UI_SPECS {
            assert_eq!(command_ui_spec(spec.id), Some(spec));
        }
        assert!(command_ui_spec(APPLY - 1).is_none());
        assert!(command_ui_spec(LAST_COMMAND + 1).is_none());
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
        assert_eq!(command_ui_spec(RESET_PATH).and_then(|spec| spec.rail), None);
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
                assert!(!spec.rail_spoken_label().is_empty());
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
                CommandEnableRule::Rows,
                CommandMutationClass::Model,
                CommandUiPolicy::AllRows,
            ))
        );
        assert_eq!(
            command_ui_spec(RESET_PATH).map(|spec| (spec.enable_rule, spec.mutation, spec.display)),
            Some((
                CommandEnableRule::Rows,
                CommandMutationClass::Model,
                CommandUiPolicy::AllRows,
            ))
        );
    }

    #[test]
    fn retained_shortcuts_are_explicit_and_conflicting_edit_shortcuts_are_removed() {
        let shortcut = |command| legacy_command_shortcut(command);
        assert_eq!(shortcut(SORT), None);
        assert_eq!(shortcut(COPY_NAMES), None);
        assert_eq!(shortcut(SAVE_NAMES), None);
        assert_eq!(shortcut(IMPORT_NAMES), None);
        assert_eq!(shortcut(RESET), None);
        assert_eq!(shortcut(EXIT_COMMAND), None);
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
            UNIFY_PATH,
            EXT_DELETE,
            EXT_ADD,
            EXT_REPLACE,
            IMPORT_NAMES,
            RESET_PATH,
        ] {
            assert_eq!(command_ui_policy(command), CommandUiPolicy::AllRows);
        }
    }

    #[test]
    fn unchanged_model_outcome_suppresses_requested_row_effect() {
        let outcome = CommandOutcome::model(false, UiEffect::AllRowsChanged);
        assert_eq!(outcome.into_effect(), UiEffect::None);

        let changed = CommandOutcome::model(
            true,
            UiEffect::ProposalRowsChanged(vec![42].into_boxed_slice()),
        );
        assert_eq!(
            changed.into_effect(),
            UiEffect::ProposalRowsChanged(vec![42].into_boxed_slice())
        );

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
            &CommandOutcome::ui(UiEffect::ProposalRowsChanged(vec![7].into_boxed_slice()))
        ));
        assert!(command_effect_fits_policy(
            MOVE_DOWN,
            &CommandOutcome::ui(UiEffect::RowsChanged(vec![6, 7].into_boxed_slice()))
        ));
        assert!(command_effect_fits_policy(
            PREFIX,
            &CommandOutcome::ui(UiEffect::ProposalRowsChanged(vec![1, 4].into_boxed_slice()))
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
    fn ten_thousand_row_proposal_plan_formats_no_immutable_columns() {
        let changed = (0..10_000).collect::<Vec<_>>();
        let plan = proposal_refresh_plan(10_000, 10_000, &changed);
        assert!(plan.is_some());
        let plan = plan.unwrap_or_default();

        assert_eq!(plan.rows.len(), 10_000);
        assert_eq!(plan.proposal_cells, 10_000);
        assert_eq!(plan.immutable_cells, 0);
        assert_eq!(plan.full_row_formats, 0);

        let one = proposal_refresh_plan(10_000, 10_000, &[9_999, 9_999]);
        assert!(one.is_some());
        let one = one.unwrap_or_default();
        assert_eq!(&*one.rows, &[9_999]);
        assert_eq!(one.proposal_cells, 1);
        assert!(proposal_refresh_plan(10_000, 9_999, &[0]).is_none());
        assert!(proposal_refresh_plan(10_000, 10_000, &[10_000]).is_none());
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
        assert!(!commands.contains(&RESET_PATH));
    }

    #[test]
    fn focus_cycles_major_regions_and_skips_unavailable_rails() {
        let mut focus = FocusState::default();
        let left = [false, true, false];
        let right = [true, false];

        assert_eq!(focus.cycle_major(&left, &right, true), FocusChild::LeftRail);
        assert_eq!(focus.left_rail_index, 1);
        assert_eq!(
            focus.cycle_major(&left, &right, true),
            FocusChild::RightRail
        );
        assert_eq!(focus.cycle_major(&left, &right, true), FocusChild::List);

        focus.record(FocusChild::LeftRail, Some(1));
        assert_eq!(focus.cycle_major(&left, &right, false), FocusChild::List);
        assert_eq!(focus.last_child, FocusChild::List);
    }

    #[test]
    fn focus_repairs_disabled_roving_targets_and_wraps_enabled_commands() {
        let mut focus = FocusState {
            last_child: FocusChild::LeftRail,
            left_rail_index: 2,
            right_rail_index: 0,
        };
        let left = [false, true, false, true];
        let right = [false, false];

        focus.repair(&left, &right, true);
        assert_eq!(focus.left_rail_index, 1);
        assert_eq!(focus.action(), FocusAction::LeftRail(1));
        assert_eq!(
            focus.active_index(FocusChild::LeftRail, &left, true),
            Some(1)
        );
        assert_eq!(
            focus.move_within_rail(true, &left, &right, true),
            Some((FocusChild::LeftRail, 3))
        );
        assert_eq!(
            focus.move_within_rail(true, &left, &right, true),
            Some((FocusChild::LeftRail, 1))
        );
        assert_eq!(
            focus.move_within_rail(false, &left, &right, true),
            Some((FocusChild::LeftRail, 3))
        );

        focus.repair(&[false; 4], &right, true);
        assert_eq!(focus.last_child, FocusChild::List);
        assert_eq!(focus.action(), FocusAction::List);
    }

    #[test]
    fn combo_result_mapping_rejects_all_documented_failure_sentinels() {
        assert_eq!(
            validate_combo_result(ComboOperation::AddString, -1),
            Err(ComboControlError::Rejected)
        );
        assert_eq!(
            validate_combo_result(ComboOperation::AddString, -2),
            Err(ComboControlError::OutOfSpace)
        );
        assert_eq!(
            validate_combo_result(ComboOperation::Select, -1),
            Err(ComboControlError::Rejected)
        );
        for success in [0, 1, 42] {
            assert_eq!(
                validate_combo_result(ComboOperation::AddString, success),
                Ok(())
            );
            assert_eq!(
                validate_combo_result(ComboOperation::Select, success),
                Ok(())
            );
        }
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
        let placements = calculate_command_rail_layout(&LEFT_RAIL, 348, metrics)?;

        assert_eq!(placements.len(), 10);
        assert!(placements.iter().all(|placement| {
            placement.x == 0
                && placement.width == 52
                && placement.height == 32
                && placement.bottom() <= 344
        }));
        assert!(
            placements
                .windows(2)
                .all(|pair| pair[0].bottom() <= pair[1].y)
        );
        assert_eq!(
            placements.last().map(|placement| placement.bottom()),
            Some(344)
        );
        assert_eq!(placements[9].bottom() + 4, 348);

        for start in [1, 4, 7] {
            assert_eq!(
                placements[start].y - placements[start - 1].bottom(),
                metrics.group_gap
            );
        }
        let separators = calculate_command_rail_separator_layout(&placements, 96);
        assert_eq!(separators.len(), 3);
        for (separator, start) in separators.iter().zip([1, 4, 7]) {
            assert!(separator.y >= placements[start - 1].bottom());
            assert!(separator.bottom() <= placements[start].y);
            assert!(separator.width > 0);
            assert!(separator.height > 0);
        }
        let apply = placements[0];
        let indicator = calculate_apply_readiness_indicator_rect(
            LayoutRect {
                x: apply.x,
                y: apply.y,
                width: apply.width,
                height: apply.height,
            },
            96,
        )
        .unwrap_or_default();
        assert!(indicator.x > apply.x);
        assert!(indicator.x + indicator.width < apply.x + apply.width);
        assert!(indicator.y > apply.y);
        assert!(indicator.bottom() < apply.bottom());
        assert!(indicator.width > 0);
        assert!(indicator.height > 0);

        let right = calculate_command_rail_layout(&RIGHT_RAIL, 348, metrics)?;
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
                    rail_top_padding: 0,
                    rail_bottom_padding: 4,
                    button_height: 32,
                    group_gap: 8,
                    rail_width: 52
                },
                UiMetrics {
                    rail_top_padding: 0,
                    rail_bottom_padding: 5,
                    button_height: 40,
                    group_gap: 10,
                    rail_width: 65
                },
                UiMetrics {
                    rail_top_padding: 0,
                    rail_bottom_padding: 6,
                    button_height: 48,
                    group_gap: 12,
                    rail_width: 78
                },
                UiMetrics {
                    rail_top_padding: 0,
                    rail_bottom_padding: 8,
                    button_height: 64,
                    group_gap: 16,
                    rail_width: 104
                },
            ]
        );
    }

    #[test]
    fn apply_readiness_indicator_stays_inside_full_width_apply_at_supported_dpis()
    -> Result<(), LayoutError> {
        for dpi in [96, 120, 144, 192] {
            let metrics = RailDensity::Comfortable.metrics(dpi);
            let available = required_command_rail_height(&LEFT_RAIL, metrics)?;
            let placements = calculate_command_rail_layout(&LEFT_RAIL, available, metrics)?;
            let apply = placements[0];
            assert_eq!(apply.command, APPLY);
            assert_eq!(apply.x, 0);
            assert_eq!(apply.y, 0);
            assert_eq!(apply.width, metrics.rail_width);
            assert_eq!(
                placements.last().map(|placement| placement.bottom()),
                Some(available - metrics.rail_bottom_padding)
            );

            let indicator = calculate_apply_readiness_indicator_rect(
                LayoutRect {
                    x: apply.x,
                    y: apply.y,
                    width: apply.width,
                    height: apply.height,
                },
                dpi,
            );
            assert!(indicator.is_some());
            let indicator = indicator.unwrap_or_default();
            assert!(indicator.x > apply.x);
            assert!(indicator.y > apply.y);
            assert!(indicator.x + indicator.width < apply.x + apply.width);
            assert!(indicator.bottom() < apply.bottom());
        }
        Ok(())
    }

    #[test]
    fn compact_rail_keeps_the_longest_two_line_label_width() {
        assert_eq!(RailDensity::Compact.metrics(96).rail_width, 52);
        assert_eq!(RailDensity::Compact.metrics(192).rail_width, 104);
        assert_eq!(
            rail_tool_spec(RESET).map(|tool| tool.label),
            Some("이름\n초기화")
        );
    }

    #[test]
    fn command_rail_density_falls_back_and_reports_insufficient_height() {
        assert_eq!(
            select_command_rail_density(348, 96),
            Ok(RailDensity::Comfortable)
        );
        assert_eq!(
            select_command_rail_density(347, 96),
            Ok(RailDensity::Compact)
        );
        assert_eq!(
            select_command_rail_density(294, 96),
            Ok(RailDensity::Compact)
        );
        assert_eq!(
            select_command_rail_density(293, 96),
            Err(LayoutError::InsufficientHeight {
                required: 294,
                available: 293,
            })
        );
    }

    #[test]
    fn appearance_defaults_and_forced_colors_precedence_are_fail_closed() {
        let defaults = UiAppearance::default();
        assert_eq!(defaults.theme, AppThemeMode::System);
        assert_eq!(defaults.density, RailDensityPreference::Automatic);
        assert_eq!(defaults.emphasis, PreviewEmphasis::Standard);
        assert!(defaults.show_separators);
        assert!(defaults.show_preview_tint);
        assert!(defaults.show_empty_safety);

        let custom = UiAppearance {
            theme: AppThemeMode::Dark,
            density: RailDensityPreference::Comfortable,
            emphasis: PreviewEmphasis::Strong,
            show_separators: false,
            show_preview_tint: true,
            show_empty_safety: false,
        };
        let ordinary = custom.resolve(ForcedColorsState::Inactive, Some(ResolvedTheme::Dark));
        assert_eq!(ordinary.appearance, custom);
        assert_eq!(ordinary.theme, ResolvedTheme::Dark);
        assert!(ordinary.custom_colors_enabled);

        let forced = custom.resolve(
            ForcedColorsState::ActiveOrUnknown,
            Some(ResolvedTheme::Dark),
        );
        assert_eq!(forced.appearance.theme, AppThemeMode::System);
        assert_eq!(forced.theme, ResolvedTheme::NativeSystem);
        assert!(!forced.appearance.show_preview_tint);
        assert!(!forced.custom_colors_enabled);
        assert_eq!(forced.appearance.density, custom.density);
        assert_eq!(
            forced.appearance.show_empty_safety,
            custom.show_empty_safety
        );

        let system = UiAppearance::default();
        assert_eq!(
            system
                .resolve(ForcedColorsState::Inactive, Some(ResolvedTheme::Dark))
                .theme,
            ResolvedTheme::Dark
        );
        let unavailable = system.resolve(ForcedColorsState::Inactive, None);
        assert_eq!(unavailable.theme, ResolvedTheme::NativeSystem);
        assert!(!unavailable.custom_colors_enabled);
        assert_eq!(semantic_palette(unavailable.theme), None);
        assert_eq!(
            dwm_frame_action(ResolvedTheme::NativeSystem, false),
            DwmFrameAction::None
        );
        assert_eq!(
            dwm_frame_action(ResolvedTheme::Dark, false),
            DwmFrameAction::SetDark(true)
        );
        assert_eq!(
            dwm_frame_action(ResolvedTheme::NativeSystem, true),
            DwmFrameAction::SetDark(false)
        );
        assert_eq!(theme_from_foreground(245, 245, 245), ResolvedTheme::Dark);
        assert_eq!(theme_from_foreground(24, 24, 24), ResolvedTheme::Light);
    }

    #[test]
    fn input_prompt_theme_requires_complete_resources_and_control_routing() {
        let custom = UiAppearance {
            theme: AppThemeMode::Dark,
            ..UiAppearance::default()
        }
        .resolve(ForcedColorsState::Inactive, Some(ResolvedTheme::Light));
        assert!(prompt_custom_theme_enabled(custom, true, true));
        assert!(!prompt_custom_theme_enabled(custom, false, true));
        assert!(!prompt_custom_theme_enabled(custom, true, false));

        let native = UiAppearance::default().resolve(ForcedColorsState::Inactive, None);
        assert!(!prompt_custom_theme_enabled(native, true, true));
        let forced = UiAppearance::default().resolve(
            ForcedColorsState::ActiveOrUnknown,
            Some(ResolvedTheme::Dark),
        );
        assert!(!prompt_custom_theme_enabled(forced, true, true));
    }

    #[test]
    fn auxiliary_theme_commands_are_presentation_only_and_safely_classified() {
        let original = UiAppearance {
            theme: AppThemeMode::System,
            density: RailDensityPreference::Compact,
            emphasis: PreviewEmphasis::Strong,
            show_separators: false,
            show_preview_tint: false,
            show_empty_safety: true,
        };
        for (command, theme) in [
            (THEME_SYSTEM, AppThemeMode::System),
            (THEME_LIGHT, AppThemeMode::Light),
            (THEME_DARK, AppThemeMode::Dark),
        ] {
            assert!(command > VERSION);
            assert!(command_ui_spec(command).is_none());
            assert_eq!(theme_mode_for_command(command), Some(theme));
            assert_eq!(theme_command_for_mode(theme), command);
            assert!(appearance_command_allowed(command, false));
            assert!(appearance_command_allowed(command, true));
            let updated = appearance_after_theme_command(original, command);
            assert_eq!(updated.map(|appearance| appearance.theme), Some(theme));
            assert_eq!(
                updated.map(|appearance| appearance.density),
                Some(original.density)
            );
            assert_eq!(
                updated.map(|appearance| appearance.emphasis),
                Some(original.emphasis)
            );
        }
        assert!(appearance_command_allowed(APPEARANCE_ADVANCED, false));
        assert!(!appearance_command_allowed(APPEARANCE_ADVANCED, true));
        assert_eq!(appearance_after_theme_command(original, VERSION), None);
        let outcome = CommandOutcome::ui(UiEffect::AppearanceChanged);
        assert!(command_effect_fits_policy(THEME_DARK, &outcome));
        assert!(!command_effect_fits_policy(COPY_NAMES, &outcome));
    }

    #[test]
    fn preview_emphasis_tint_and_native_precedence_are_semantic() {
        let base = UiAppearance::default();
        let light = base.resolve(ForcedColorsState::Inactive, Some(ResolvedTheme::Light));
        let subtle = proposed_name_colors(
            ResolvedUiAppearance {
                appearance: UiAppearance {
                    emphasis: PreviewEmphasis::Subtle,
                    ..base
                },
                ..light
            },
            ProposedNameVisual::Changed,
        );
        let strong = proposed_name_colors(
            ResolvedUiAppearance {
                appearance: UiAppearance {
                    emphasis: PreviewEmphasis::Strong,
                    show_preview_tint: false,
                    ..base
                },
                ..light
            },
            ProposedNameVisual::Changed,
        );
        assert_eq!(
            subtle.map(|colors| colors.text),
            Some(PRECISION_LIGHT.changed_subtle)
        );
        assert_eq!(
            subtle.and_then(|colors| colors.background),
            Some(PRECISION_LIGHT.preview_tint)
        );
        assert_eq!(
            strong.map(|colors| colors.text),
            Some(PRECISION_LIGHT.changed_strong)
        );
        assert_eq!(strong.and_then(|colors| colors.background), None);
        assert_eq!(
            proposed_name_colors(light, ProposedNameVisual::Warning).map(|colors| colors.text),
            Some(PRECISION_LIGHT.warning)
        );
        assert_eq!(
            proposed_name_colors(light, ProposedNameVisual::Collision).map(|colors| colors.text),
            Some(PRECISION_LIGHT.collision)
        );
        assert_eq!(
            proposed_name_colors(light, ProposedNameVisual::Default),
            None
        );

        let forced = base.resolve(
            ForcedColorsState::ActiveOrUnknown,
            Some(ResolvedTheme::Dark),
        );
        assert_eq!(semantic_palette(forced.theme), None);
        assert_eq!(
            proposed_name_colors(forced, ProposedNameVisual::Changed),
            None
        );
        assert_ne!(
            semantic_palette(ResolvedTheme::Light),
            semantic_palette(ResolvedTheme::Dark)
        );
    }

    #[test]
    fn advanced_appearance_model_previews_resets_accepts_and_cancels_exactly() {
        let original = UiAppearance {
            theme: AppThemeMode::Dark,
            density: RailDensityPreference::Compact,
            emphasis: PreviewEmphasis::Strong,
            show_separators: false,
            show_preview_tint: false,
            show_empty_safety: false,
        };
        let mut model = AppearanceDialogModel::new(original, ForcedColorsState::Inactive);
        assert_eq!(
            model.apply(AppearanceDialogAction::Density(
                RailDensityPreference::Comfortable,
            )),
            AppearanceDialogEffect::Preview(UiAppearance {
                density: RailDensityPreference::Comfortable,
                ..original
            })
        );
        assert!(matches!(
            model.apply(AppearanceDialogAction::ShowSeparators(true)),
            AppearanceDialogEffect::Preview(UiAppearance {
                show_separators: true,
                ..
            })
        ));
        assert!(matches!(
            model.apply(AppearanceDialogAction::ShowEmptySafety(true)),
            AppearanceDialogEffect::Preview(UiAppearance {
                show_empty_safety: true,
                ..
            })
        ));
        assert_eq!(
            model.apply(AppearanceDialogAction::ResetDefaults),
            AppearanceDialogEffect::Preview(UiAppearance {
                theme: AppThemeMode::Dark,
                ..UiAppearance::default()
            })
        );
        assert_eq!(
            model.apply(AppearanceDialogAction::Accept),
            AppearanceDialogEffect::Accept(UiAppearance {
                theme: AppThemeMode::Dark,
                ..UiAppearance::default()
            })
        );
        assert_eq!(
            model.apply(AppearanceDialogAction::Cancel),
            AppearanceDialogEffect::Cancel(original)
        );
        assert_eq!(model.draft(), original);

        let mut menu_only = AppearanceDialogModel::new(original, ForcedColorsState::Inactive);
        assert_eq!(
            menu_only.apply(AppearanceDialogAction::Density(
                RailDensityPreference::MenuOnly,
            )),
            AppearanceDialogEffect::Preview(UiAppearance {
                density: RailDensityPreference::MenuOnly,
                ..original
            })
        );

        let mut forced = AppearanceDialogModel::new(original, ForcedColorsState::ActiveOrUnknown);
        assert_eq!(forced.forced_colors(), ForcedColorsState::ActiveOrUnknown);
        assert_eq!(
            forced.apply(AppearanceDialogAction::Emphasis(PreviewEmphasis::Subtle,)),
            AppearanceDialogEffect::None
        );
        assert_eq!(
            forced.apply(AppearanceDialogAction::ShowPreviewTint(true)),
            AppearanceDialogEffect::None
        );
        assert_eq!(forced.draft(), original);
        forced.set_forced_colors(ForcedColorsState::Inactive);
        assert_eq!(forced.forced_colors(), ForcedColorsState::Inactive);
        assert!(!advanced_appearance_available(true, false));
        assert!(!advanced_appearance_available(false, true));
        assert!(advanced_appearance_available(false, false));
        assert!(!appearance_dialog_should_notify_cancel(false, false));
        assert!(!appearance_dialog_should_notify_cancel(false, true));
        assert!(!appearance_dialog_should_notify_cancel(true, true));
        assert!(appearance_dialog_should_notify_cancel(true, false));
    }

    #[test]
    fn appearance_preview_payload_is_strict_and_round_trips_every_setting() {
        for theme in [
            AppThemeMode::System,
            AppThemeMode::Light,
            AppThemeMode::Dark,
        ] {
            for density in [
                RailDensityPreference::Automatic,
                RailDensityPreference::Comfortable,
                RailDensityPreference::Compact,
                RailDensityPreference::MenuOnly,
            ] {
                for emphasis in [
                    PreviewEmphasis::Subtle,
                    PreviewEmphasis::Standard,
                    PreviewEmphasis::Strong,
                ] {
                    for flags in 0_u8..8 {
                        let appearance = UiAppearance {
                            theme,
                            density,
                            emphasis,
                            show_separators: flags & 1 != 0,
                            show_preview_tint: flags & 2 != 0,
                            show_empty_safety: flags & 4 != 0,
                        };
                        assert_eq!(
                            unpack_ui_appearance(pack_ui_appearance(appearance)),
                            Some(appearance)
                        );
                    }
                }
            }
        }
        for invalid in [0x3, 0x30, 1 << 9, u32::MAX] {
            assert_eq!(unpack_ui_appearance(invalid), None);
        }
    }

    #[test]
    fn preinstall_appearance_dialog_destruction_emits_no_owner_callback() {
        assert!(!appearance_dialog_should_notify_cancel(false, false));
        assert!(appearance_dialog_should_notify_cancel(true, false));
        assert!(!appearance_dialog_should_notify_cancel(true, true));
    }

    #[test]
    fn advanced_appearance_layout_keeps_every_control_inside_work_area_bounds() {
        for (dpi, width, height) in [
            (96, 360, 300),
            (120, 450, 360),
            (144, 540, 400),
            (192, 720, 500),
            (240, 900, 600),
            (288, 1_080, 700),
        ] {
            let layout = calculate_appearance_dialog_layout(
                dpi,
                width,
                height,
                true,
                AppearanceDialogMetrics::default(),
            );
            assert!(layout.is_some(), "valid work area rejected at {dpi} DPI");
            let Some(layout) = layout else {
                continue;
            };
            let body_rects = [
                layout.density_group,
                layout.density_options[0],
                layout.density_options[1],
                layout.density_options[2],
                layout.density_options[3],
                layout.emphasis_group,
                layout.emphasis_options[0],
                layout.emphasis_options[1],
                layout.emphasis_options[2],
                layout.forced_explanation,
                layout.checkboxes[0],
                layout.checkboxes[1],
                layout.checkboxes[2],
                layout.separator,
            ];
            assert!(layout.client.width <= width);
            assert!(layout.client.height <= height);
            assert_eq!(layout.body_viewport.y, 0);
            assert_eq!(layout.footer.y, layout.body_viewport.height);
            assert_eq!(layout.footer.bottom(), layout.client.height);
            assert_eq!(layout.scroll_page, layout.body_viewport.height);
            assert_eq!(
                layout.scroll_max,
                layout.body_content_height - layout.scroll_page
            );
            assert_eq!(layout.separator.height, scale_dip(1, dpi));
            for rect in body_rects {
                assert!(rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0);
                assert!(rect.x.saturating_add(rect.width) <= layout.client.width);
                assert!(rect.bottom() <= layout.body_content_height);
            }
            for rect in [layout.reset, layout.ok, layout.cancel] {
                assert!(rect.x >= 0 && rect.y >= layout.footer.y);
                assert!(rect.x.saturating_add(rect.width) <= layout.client.width);
                assert!(rect.bottom() <= layout.client.height);
            }
        }
        assert_eq!(
            calculate_appearance_dialog_layout(
                192,
                320,
                300,
                true,
                AppearanceDialogMetrics::default(),
            ),
            None
        );
        assert_eq!(
            calculate_appearance_dialog_layout(
                192,
                320,
                300,
                false,
                AppearanceDialogMetrics::default(),
            ),
            None
        );
        let layout = calculate_appearance_dialog_layout(
            96,
            360,
            300,
            true,
            AppearanceDialogMetrics::default(),
        );
        assert!(
            layout.is_some(),
            "baseline appearance dialog layout was rejected"
        );
        let Some(layout) = layout else {
            return;
        };
        let body_interactive = [
            layout.density_options[0],
            layout.density_options[1],
            layout.density_options[2],
            layout.density_options[3],
            layout.emphasis_options[0],
            layout.emphasis_options[1],
            layout.emphasis_options[2],
            layout.checkboxes[0],
            layout.checkboxes[1],
            layout.checkboxes[2],
        ];
        assert!(
            body_interactive
                .iter()
                .all(|rect| rect.width > 0 && rect.height > 0)
        );
        for (index, left) in body_interactive.iter().enumerate() {
            for right in &body_interactive[index + 1..] {
                let overlaps = left.x < right.x.saturating_add(right.width)
                    && right.x < left.x.saturating_add(left.width)
                    && left.y < right.bottom()
                    && right.y < left.bottom();
                assert!(!overlaps);
            }
        }

        let ordinary = calculate_appearance_dialog_layout(
            96,
            360,
            300,
            false,
            AppearanceDialogMetrics::default(),
        );
        let forced = calculate_appearance_dialog_layout(
            96,
            360,
            300,
            true,
            AppearanceDialogMetrics::default(),
        );
        let (Some(ordinary), Some(forced)) = (ordinary, forced) else {
            return;
        };
        assert_eq!(ordinary.forced_explanation.width, 0);
        assert_eq!(ordinary.forced_explanation.height, 0);
        assert!(forced.forced_explanation.width > 0);
        assert!(forced.forced_explanation.height > 0);
        assert_eq!(
            forced.checkboxes[0].y - ordinary.checkboxes[0].y,
            scale_dip(48, 96)
        );
        assert_eq!(ordinary.footer, forced.footer);
        assert_eq!(ordinary.reset, forced.reset);
        assert_eq!(ordinary.ok, forced.ok);
        assert_eq!(ordinary.cancel, forced.cancel);
        assert!(forced.scroll_max > ordinary.scroll_max);

        let large = calculate_appearance_dialog_layout(
            96,
            900,
            900,
            true,
            AppearanceDialogMetrics {
                text_height: 36,
                widest_option: 520,
                widest_checkbox: 600,
                button_text_height: 34,
                widest_button: 180,
                wrapped_option_height: 72,
                wrapped_checkbox_height: 80,
                forced_explanation_height: 110,
            },
        );
        assert!(
            large.is_some(),
            "large measured system font should fit the supplied work area"
        );
        let Some(large) = large else {
            return;
        };
        assert!(large.client.width > forced.client.width);
        assert!(large.density_options[0].height >= 42);
        assert!(large.cancel.height >= 46);
        assert!(large.forced_explanation.height >= 110);
    }

    #[test]
    fn advanced_appearance_layout_reflows_footer_and_clamps_scroll() {
        let layout = calculate_appearance_dialog_layout(
            96,
            260,
            220,
            true,
            AppearanceDialogMetrics::default(),
        );
        assert!(layout.is_some());
        let Some(layout) = layout else {
            return;
        };
        assert!(layout.compact_footer);
        assert!(layout.reset.bottom() <= layout.ok.y);
        assert_eq!(layout.ok.y, layout.cancel.y);
        assert!(layout.footer.y >= layout.body_viewport.bottom());
        assert!(layout.scroll_max > 0);
        assert_eq!(clamp_appearance_dialog_scroll(layout, -10), 0);
        assert_eq!(
            clamp_appearance_dialog_scroll(layout, i32::MAX),
            layout.scroll_max
        );
    }

    #[test]
    fn appearance_model_draft_survives_relayout_inputs() {
        let original = UiAppearance::default();
        let mut model = AppearanceDialogModel::new(original, ForcedColorsState::Inactive);
        assert!(matches!(
            model.apply(AppearanceDialogAction::Density(
                RailDensityPreference::MenuOnly
            )),
            AppearanceDialogEffect::Preview(_)
        ));
        let draft = model.draft();
        for dpi in [96, 120, 144, 192, 240, 288] {
            let layout = calculate_appearance_dialog_layout(
                dpi,
                scale_dip(360, dpi),
                scale_dip(240, dpi),
                false,
                AppearanceDialogMetrics::default(),
            );
            assert!(layout.is_some());
            assert_eq!(model.draft(), draft);
        }
    }

    #[test]
    fn empty_state_layout_uses_exact_second_pass_wrapped_heights() {
        let measured = MeasuredFontMetrics {
            empty_instruction_text_width: 2_000,
            empty_instruction_text_height: 20,
            empty_safety_text_width: 3_000,
            empty_safety_text_height: 18,
            empty_wrap_width: 300,
            empty_instruction_wrapped_height: 41,
            empty_safety_wrapped_height: 59,
            ..MeasuredFontMetrics::default()
        };

        let content = measured.empty_state_content_metrics(96, 300, true);

        assert_eq!(content.instruction_height, 41);
        assert_eq!(content.safety_height, 59);
        assert!(content.total_height >= 100);
    }

    #[test]
    fn explicit_density_preferences_never_silently_substitute_the_other_density() {
        assert_eq!(
            select_command_rail_density_with_preference(
                348,
                96,
                RailDensityPreference::Comfortable,
            ),
            Ok(RailDensity::Comfortable)
        );
        assert!(matches!(
            select_command_rail_density_with_preference(
                347,
                96,
                RailDensityPreference::Comfortable,
            ),
            Err(LayoutError::InsufficientHeight { .. })
        ));
        assert_eq!(
            select_command_rail_density_with_preference(294, 96, RailDensityPreference::Compact),
            Ok(RailDensity::Compact)
        );
        assert!(matches!(
            select_command_rail_density_with_preference(293, 96, RailDensityPreference::Compact),
            Err(LayoutError::InsufficientHeight { .. })
        ));

        let measured = MeasuredFontMetrics::default();
        let automatic =
            calculate_main_layout(464, 365, 96, measured, RailDensityPreference::Automatic);
        let comfortable =
            calculate_main_layout(464, 365, 96, measured, RailDensityPreference::Comfortable);
        let compact = calculate_main_layout(464, 365, 96, measured, RailDensityPreference::Compact);
        let menu_only =
            calculate_main_layout(464, 365, 96, measured, RailDensityPreference::MenuOnly);
        assert_eq!(automatic.rail_mode, RailMode::Compact);
        assert_eq!(comfortable.rail_mode, RailMode::MenuOnly);
        assert_eq!(compact.rail_mode, RailMode::Compact);
        assert_eq!(menu_only.rail_mode, RailMode::MenuOnly);
        assert!(menu_only.left_buttons.is_empty());
        assert!(menu_only.right_buttons.is_empty());
        assert_eq!(
            minimum_main_client_height(96, measured, RailDensityPreference::Automatic),
            minimum_main_client_height(96, measured, RailDensityPreference::Compact)
        );
        assert!(
            minimum_main_client_height(96, measured, RailDensityPreference::Comfortable)
                > minimum_main_client_height(96, measured, RailDensityPreference::Compact)
        );
        assert_eq!(
            recommended_main_client_height(96, measured, RailDensityPreference::Automatic),
            recommended_main_client_height(96, measured, RailDensityPreference::Comfortable)
        );
        assert_eq!(
            recommended_main_client_height(96, measured, RailDensityPreference::Compact),
            minimum_main_client_height(96, measured, RailDensityPreference::Compact)
        );
        assert_eq!(
            recommended_main_client_height(96, measured, RailDensityPreference::MenuOnly),
            minimum_main_client_height(96, measured, RailDensityPreference::MenuOnly)
        );
        assert!(
            minimum_main_client_height(96, measured, RailDensityPreference::MenuOnly)
                < minimum_main_client_height(96, measured, RailDensityPreference::Compact)
        );
    }

    #[test]
    fn measured_font_metrics_expand_rail_and_status_geometry() {
        let measured = MeasuredFontMetrics {
            button_text_width: 90,
            button_text_height: 44,
            status_text_height: 24,
            status_count_text_width: 72,
            cancel_text_width: 48,
            cancel_text_height: 30,
            empty_instruction_text_width: 360,
            empty_instruction_text_height: 38,
            empty_safety_text_width: 960,
            empty_safety_text_height: 32,
            empty_add_text_width: 150,
            empty_add_text_height: 34,
            empty_wrap_width: 0,
            empty_instruction_wrapped_height: 0,
            empty_safety_wrapped_height: 0,
            drop_overlay_text_width: 420,
            drop_overlay_text_height: 34,
        };

        let compact = measured.rail_metrics(RailDensity::Compact, 96);
        assert!(compact.rail_width >= 100);
        assert!(compact.button_height >= 50);
        assert!(measured.status_height(96) >= 28);
        assert!(measured.empty_state_minimum_width(96) >= 384);
        assert!(
            minimum_main_client_height(96, measured, RailDensityPreference::Automatic)
                > minimum_main_client_height(
                    96,
                    MeasuredFontMetrics::default(),
                    RailDensityPreference::Automatic,
                )
        );
        assert!(
            recommended_main_client_height(96, measured, RailDensityPreference::Automatic)
                > minimum_main_client_height(96, measured, RailDensityPreference::Automatic)
        );

        let client_width = compact
            .rail_width
            .saturating_mul(2)
            .saturating_add(measured.empty_state_minimum_width(96))
            .saturating_add(2);
        let client_height =
            minimum_main_client_height(96, measured, RailDensityPreference::Automatic);
        let layout = calculate_main_layout(
            client_width,
            client_height,
            96,
            measured,
            RailDensityPreference::Automatic,
        );
        assert_eq!(layout.rail_mode, RailMode::Compact);
        let empty = measured.empty_state_content_metrics(96, layout.empty_safety.width, true);
        assert!(layout.empty_instruction.height >= empty.instruction_height);
        assert!(layout.empty_safety.height >= empty.safety_height);
        assert!(layout.empty_add.height >= empty.add_height);
        assert!(layout.empty_add.width >= 174);
        assert!(layout.empty_safety.bottom() <= layout.list.bottom());
    }

    #[test]
    fn drop_overlay_wraps_large_text_inside_a_narrow_list() {
        let measured = MeasuredFontMetrics {
            drop_overlay_text_width: 1_000,
            drop_overlay_text_height: 40,
            ..MeasuredFontMetrics::default()
        };
        let list = LayoutRect {
            x: 10,
            y: 5,
            width: 120,
            height: 800,
        };
        let overlay = calculate_drop_overlay_layout(list, 96, measured);
        let expected_text_height = conservative_wrapped_text_height(
            measured.drop_overlay_text_width,
            measured.drop_overlay_text_height,
            overlay.width,
        );
        assert!(overlay.height >= expected_text_height + scale_dip(10, 96));
        assert!(overlay.x >= list.x);
        assert!(overlay.y >= list.y);
        assert!(overlay.x + overlay.width <= list.x + list.width);
        assert!(overlay.bottom() <= list.bottom());
    }

    #[test]
    fn minimum_height_expands_for_large_wrapped_empty_state_copy() {
        let measured = MeasuredFontMetrics {
            empty_instruction_text_width: 320,
            empty_instruction_text_height: 48,
            empty_safety_text_width: 4_000,
            empty_safety_text_height: 48,
            empty_add_text_width: 180,
            empty_add_text_height: 44,
            ..MeasuredFontMetrics::default()
        };
        let rail_width = measured
            .rail_metrics(RailDensity::Comfortable, 96)
            .rail_width;
        let client_width = rail_width
            .saturating_mul(2)
            .saturating_add(measured.empty_state_minimum_width(96))
            .saturating_add(2);
        let client_height =
            minimum_main_client_height(96, measured, RailDensityPreference::Automatic);
        let rail_only_height =
            required_command_rail_height(&LEFT_RAIL, RailDensity::Compact.metrics(96))
                .unwrap_or_default()
                .saturating_add(measured.status_height(96));
        assert!(client_height > rail_only_height);

        let layout = calculate_main_layout(
            client_width,
            client_height,
            96,
            measured,
            RailDensityPreference::Automatic,
        );
        let content = measured.empty_state_content_metrics(96, layout.empty_safety.width, true);
        assert!(layout.empty_instruction.height >= content.instruction_height);
        assert!(layout.empty_safety.height >= content.safety_height);
        assert!(layout.empty_add.height >= content.add_height);
        assert!(layout.empty_safety.bottom() <= layout.list.bottom());
    }

    #[test]
    fn hiding_empty_safety_removes_its_rect_gap_and_minimum_height() {
        let measured = MeasuredFontMetrics {
            empty_instruction_text_width: 240,
            empty_instruction_text_height: 24,
            empty_safety_text_width: 3_000,
            empty_safety_text_height: 40,
            empty_add_text_width: 140,
            empty_add_text_height: 30,
            ..MeasuredFontMetrics::default()
        };
        let with_safety = minimum_main_client_height_with_safety(
            96,
            measured,
            RailDensityPreference::Automatic,
            true,
        );
        let without_safety = minimum_main_client_height_with_safety(
            96,
            measured,
            RailDensityPreference::Automatic,
            false,
        );
        assert!(without_safety < with_safety);
        assert!(
            recommended_main_client_height_with_safety(
                96,
                measured,
                RailDensityPreference::Automatic,
                false,
            ) < recommended_main_client_height_with_safety(
                96,
                measured,
                RailDensityPreference::Automatic,
                true,
            )
        );
        let width = measured
            .rail_metrics(RailDensity::Compact, 96)
            .rail_width
            .saturating_mul(2)
            .saturating_add(measured.empty_state_minimum_width(96))
            .saturating_add(2);
        let hidden = calculate_main_layout_with_safety(
            width,
            without_safety,
            96,
            measured,
            RailDensityPreference::Automatic,
            false,
            StatusLayoutInput::default(),
        );
        let hidden_content =
            measured.empty_state_content_metrics(96, hidden.empty_instruction.width, false);
        assert_eq!(hidden.empty_safety.height, 0);
        assert_eq!(hidden.empty_safety.y, hidden.empty_add.bottom());
        assert_eq!(
            hidden.empty_instruction.y,
            hidden.list.y.saturating_add(
                hidden
                    .list
                    .height
                    .saturating_sub(hidden_content.total_height)
                    / 2,
            ),
        );
        let shown = calculate_main_layout_with_safety(
            width,
            with_safety,
            96,
            measured,
            RailDensityPreference::Automatic,
            true,
            StatusLayoutInput::default(),
        );
        let shown_content =
            measured.empty_state_content_metrics(96, shown.empty_instruction.width, true);
        assert!(shown.empty_safety.height > 0);
        assert!(shown.empty_safety.y > shown.empty_add.bottom());
        assert_eq!(
            shown.empty_instruction.y,
            shown
                .list
                .y
                .saturating_add(shown.list.height.saturating_sub(shown_content.total_height) / 2,),
        );
    }

    #[test]
    fn status_layout_returns_hidden_cancel_width_and_uses_current_count_width() {
        let measured = MeasuredFontMetrics {
            status_text_height: 16,
            status_count_text_width: 400,
            cancel_text_width: 52,
            cancel_text_height: 20,
            ..MeasuredFontMetrics::default()
        };
        let hidden = calculate_main_layout_with_safety(
            800,
            500,
            96,
            measured,
            RailDensityPreference::Automatic,
            true,
            StatusLayoutInput {
                cancel_visible: false,
                measured_count_width: 120,
            },
        );
        assert_eq!(hidden.cancel.width, 0);
        assert_eq!(hidden.status_count.width, 120);
        assert_eq!(hidden.status_message.width, 648);
        assert_eq!(hidden.status_chrome.outer.width, 800);
        assert_eq!(hidden.status_chrome.message_count_boundary, 664);
        assert_eq!(hidden.status_chrome.top_line_right, 800);
        assert_eq!(hidden.status_message.x, 8);
        assert_eq!(hidden.status_count.x, 672);

        let visible = calculate_main_layout_with_safety(
            800,
            500,
            96,
            measured,
            RailDensityPreference::Automatic,
            true,
            StatusLayoutInput {
                cancel_visible: true,
                measured_count_width: 120,
            },
        );
        assert_eq!(visible.cancel.width, 68);
        assert_eq!(visible.status_count.width, 120);
        assert_eq!(visible.status_message.width, 580);
        assert_eq!(visible.status_chrome.outer.width, 800);
        assert_eq!(visible.status_chrome.message_count_boundary, 596);
        assert_eq!(visible.status_chrome.top_line_right, 732);
        assert_eq!(visible.status_message.x, 8);
        assert_eq!(visible.status_count.x, 604);
        assert_eq!(
            visible.status_chrome.top_line_right + visible.cancel.width,
            800
        );
    }

    #[test]
    fn status_layout_scales_padding_and_preserves_nonnegative_narrow_geometry() {
        let measured = MeasuredFontMetrics {
            status_text_height: 16,
            cancel_text_width: 52,
            cancel_text_height: 20,
            ..MeasuredFontMetrics::default()
        };
        for dpi in [96, 120, 144, 192] {
            let padding = scale_dip(8, dpi);
            let measured_count = scale_dip(60, dpi);
            let layout = calculate_main_layout_with_safety(
                scale_dip(480, dpi),
                scale_dip(320, dpi),
                dpi,
                measured,
                RailDensityPreference::Automatic,
                true,
                StatusLayoutInput {
                    cancel_visible: false,
                    measured_count_width: measured_count,
                },
            );
            assert_eq!(
                layout.status_chrome.top_line_right,
                layout.status_chrome.outer.right()
            );
            assert_eq!(
                layout.status_chrome.outer.width,
                layout.status_chrome.message_count_boundary
                    + measured_count
                    + padding.saturating_mul(2)
            );
            assert_eq!(layout.status_message.x, padding);
            assert_eq!(
                layout.status_message.y,
                layout.status_chrome.outer.y.saturating_add(1)
            );
            assert_eq!(
                layout.status_message.bottom(),
                layout.status_chrome.outer.bottom()
            );
            assert_eq!(
                layout.status_count.x,
                layout
                    .status_chrome
                    .message_count_boundary
                    .saturating_add(padding)
            );
            assert_eq!(layout.status_count.width, measured_count);
        }

        for cancel_visible in [false, true] {
            let layout = calculate_main_layout_with_safety(
                7,
                5,
                192,
                measured,
                RailDensityPreference::Automatic,
                true,
                StatusLayoutInput {
                    cancel_visible,
                    measured_count_width: 400,
                },
            );
            for rect in [
                layout.status_chrome.outer,
                layout.status_message,
                layout.status_count,
                layout.cancel,
            ] {
                assert!(rect.x >= 0);
                assert!(rect.y >= 0);
                assert!(rect.width >= 0);
                assert!(rect.height >= 0);
                assert!(rect.right() <= layout.status_chrome.outer.right());
            }
        }
    }

    #[test]
    fn workspace_chrome_reserves_one_physical_pixel_per_visible_rail_boundary() {
        let measured = MeasuredFontMetrics::default();
        for dpi in [96, 120, 144, 192] {
            let width = scale_dip(800, dpi);
            let height = scale_dip(500, dpi);
            for (preference, expected_mode) in [
                (RailDensityPreference::Comfortable, RailMode::Comfortable),
                (RailDensityPreference::Compact, RailMode::Compact),
            ] {
                let layout = calculate_main_layout_with_safety(
                    width,
                    height,
                    dpi,
                    measured,
                    preference,
                    true,
                    StatusLayoutInput::default(),
                );
                assert_eq!(layout.rail_mode, expected_mode);
                assert_eq!(layout.workspace_chrome.left_list_divider.width, 1);
                assert_eq!(layout.workspace_chrome.right_list_divider.width, 1);
                assert_eq!(
                    layout.workspace_chrome.left_list_divider.x,
                    layout.rail_width
                );
                assert_eq!(layout.list.x, layout.rail_width.saturating_add(1));
                assert_eq!(
                    layout.workspace_chrome.right_list_divider.x,
                    width.saturating_sub(layout.rail_width).saturating_sub(1)
                );
                assert_eq!(
                    layout.list.right(),
                    layout.workspace_chrome.right_list_divider.x
                );
                assert_eq!(
                    layout.workspace_chrome.left_list_divider.height,
                    layout.list.height
                );
                assert_eq!(
                    layout.workspace_chrome.right_list_divider.height,
                    layout.list.height
                );
                for overlay in [
                    layout.empty_instruction,
                    layout.empty_safety,
                    layout.empty_add,
                    layout.drop_overlay,
                ] {
                    assert!(overlay.x >= layout.list.x);
                    assert!(overlay.right() <= layout.list.right());
                }
            }

            let menu_only = calculate_main_layout_with_safety(
                width,
                height,
                dpi,
                measured,
                RailDensityPreference::MenuOnly,
                true,
                StatusLayoutInput::default(),
            );
            assert_eq!(menu_only.rail_mode, RailMode::MenuOnly);
            assert_eq!(menu_only.list.x, 0);
            assert_eq!(menu_only.list.width, width);
            assert_eq!(
                menu_only.workspace_chrome,
                WorkspaceChromeGeometry::default()
            );
        }
    }

    #[test]
    fn workspace_chrome_falls_back_before_narrow_dividers_can_overlap() {
        let measured = MeasuredFontMetrics::default();
        let rail_width = measured.rail_metrics(RailDensity::Compact, 96).rail_width;
        let too_narrow = calculate_main_layout_with_safety(
            rail_width.saturating_mul(2).saturating_add(2),
            1_000,
            96,
            measured,
            RailDensityPreference::Compact,
            true,
            StatusLayoutInput::default(),
        );
        assert_eq!(too_narrow.rail_mode, RailMode::MenuOnly);
        assert_eq!(
            too_narrow.workspace_chrome,
            WorkspaceChromeGeometry::default()
        );

        let one_pixel_list = calculate_main_layout_with_safety(
            rail_width.saturating_mul(2).saturating_add(3),
            1_000,
            96,
            measured,
            RailDensityPreference::Compact,
            true,
            StatusLayoutInput::default(),
        );
        assert_eq!(one_pixel_list.rail_mode, RailMode::Compact);
        assert_eq!(one_pixel_list.list.width, 1);
        assert!(one_pixel_list.workspace_chrome.left_list_divider.right() <= one_pixel_list.list.x);
        assert!(
            one_pixel_list.list.right() <= one_pixel_list.workspace_chrome.right_list_divider.x
        );
    }

    #[test]
    fn header_chrome_owns_one_bottom_line_and_unique_internal_dividers() {
        let chrome = calculate_header_chrome(
            LayoutRect {
                x: 0,
                y: 0,
                width: 500,
                height: 28,
            },
            &[100, 250, 250, 400],
        );
        assert_eq!(
            chrome.bottom_line,
            LayoutRect {
                x: 0,
                y: 27,
                width: 500,
                height: 1,
            }
        );
        assert_eq!(
            chrome.gutter,
            LayoutRect {
                x: 400,
                y: 0,
                width: 100,
                height: 27,
            }
        );
        assert_eq!(
            chrome.item_dividers,
            vec![
                LayoutRect {
                    x: 99,
                    y: 0,
                    width: 1,
                    height: 27,
                },
                LayoutRect {
                    x: 249,
                    y: 0,
                    width: 1,
                    height: 27,
                },
            ]
        );

        let clipped = calculate_header_chrome(
            LayoutRect {
                x: 0,
                y: 0,
                width: 300,
                height: 28,
            },
            &[100, 250, 400],
        );
        assert_eq!(clipped.gutter.width, 0);
        assert_eq!(
            clipped
                .item_dividers
                .iter()
                .map(|divider| divider.x)
                .collect::<Vec<_>>(),
            vec![99, 249]
        );
    }

    #[test]
    fn menu_bottom_edge_matches_observed_window_coordinates() {
        let edge = calculate_menu_bottom_edge(
            LayoutRect {
                x: 300,
                y: 200,
                width: 1_158,
                height: 1_088,
            },
            LayoutRect {
                x: 313,
                y: 250,
                width: 1_132,
                height: 46,
            },
        );

        assert_eq!(
            edge,
            Some(LayoutRect {
                x: 13,
                y: 96,
                width: 1_132,
                height: 1,
            })
        );
    }

    #[test]
    fn menu_bottom_edge_clamps_horizontally_and_rejects_invalid_geometry() {
        let window = LayoutRect {
            x: 100,
            y: 200,
            width: 300,
            height: 200,
        };
        assert_eq!(
            calculate_menu_bottom_edge(
                window,
                LayoutRect {
                    x: 50,
                    y: 220,
                    width: 400,
                    height: 30,
                },
            ),
            Some(LayoutRect {
                x: 0,
                y: 50,
                width: 300,
                height: 1,
            })
        );

        for (invalid_window, invalid_menu) in [
            (
                LayoutRect { width: 0, ..window },
                LayoutRect {
                    x: 120,
                    y: 220,
                    width: 100,
                    height: 30,
                },
            ),
            (
                window,
                LayoutRect {
                    x: 500,
                    y: 220,
                    width: 100,
                    height: 30,
                },
            ),
            (
                window,
                LayoutRect {
                    x: 120,
                    y: 170,
                    width: 100,
                    height: 30,
                },
            ),
            (
                window,
                LayoutRect {
                    x: 120,
                    y: 390,
                    width: 100,
                    height: 10,
                },
            ),
            (
                LayoutRect {
                    x: i32::MAX - 10,
                    width: 20,
                    ..window
                },
                LayoutRect {
                    x: i32::MAX - 5,
                    y: 220,
                    width: 10,
                    height: 30,
                },
            ),
            (
                window,
                LayoutRect {
                    x: 120,
                    y: i32::MAX - 5,
                    width: 100,
                    height: 10,
                },
            ),
        ] {
            assert_eq!(
                calculate_menu_bottom_edge(invalid_window, invalid_menu),
                None
            );
        }
    }

    #[test]
    fn main_layout_falls_back_from_compact_to_menu_only_without_invalid_rectangles() {
        let measured = MeasuredFontMetrics::default();
        let comfortable =
            calculate_main_layout(464, 366, 96, measured, RailDensityPreference::Automatic);
        assert_eq!(comfortable.rail_mode, RailMode::Comfortable);
        assert_eq!(main_layout_window_count(&comfortable), 34);

        let compact =
            calculate_main_layout(464, 365, 96, measured, RailDensityPreference::Automatic);
        assert_eq!(compact.rail_mode, RailMode::Compact);

        let vertical_menu_only =
            calculate_main_layout(464, 311, 96, measured, RailDensityPreference::Automatic);
        assert_eq!(vertical_menu_only.rail_mode, RailMode::MenuOnly);
        assert_eq!(main_layout_window_count(&vertical_menu_only), 8);

        let menu_only =
            calculate_main_layout(80, 40, 96, measured, RailDensityPreference::Automatic);
        assert_eq!(menu_only.rail_mode, RailMode::MenuOnly);
        for rect in [
            menu_only.list,
            menu_only.status_message,
            menu_only.status_count,
            menu_only.cancel,
            menu_only.empty_instruction,
            menu_only.empty_safety,
            menu_only.empty_add,
            menu_only.drop_overlay,
        ] {
            assert!(rect.x >= 0);
            assert!(rect.y >= 0);
            assert!(rect.width >= 0);
            assert!(rect.height >= 0);
        }
        assert_eq!(menu_only.list.width, 80);
        assert_eq!(menu_only.status_message.x, scale_dip(8, 96));
        assert_eq!(menu_only.cancel.x + menu_only.cancel.width, 80);
        assert_eq!(menu_only.status_chrome.outer.width, 80);
        assert_eq!(
            menu_only.list.height + menu_only.status_chrome.outer.height,
            40
        );
        for overlay in [
            comfortable.empty_instruction,
            comfortable.empty_add,
            comfortable.empty_safety,
            comfortable.drop_overlay,
        ] {
            assert!(overlay.x >= comfortable.list.x);
            assert!(overlay.y >= comfortable.list.y);
            assert!(overlay.x + overlay.width <= comfortable.list.x + comfortable.list.width);
            assert!(overlay.bottom() <= comfortable.list.bottom());
        }
    }

    #[test]
    fn rail_safety_copy_balances_without_forcing_menu_only_wrap() {
        assert_eq!(
            empty_state_safety_copy(RailMode::Comfortable),
            EMPTY_STATE_SAFETY_RAILS
        );
        assert_eq!(
            empty_state_safety_copy(RailMode::Compact),
            EMPTY_STATE_SAFETY_RAILS
        );
        assert_eq!(
            empty_state_safety_copy(RailMode::MenuOnly),
            EMPTY_STATE_SAFETY
        );
        assert!(!EMPTY_STATE_SAFETY.contains('\r'));
        assert!(!EMPTY_STATE_SAFETY.contains('\n'));
    }

    #[test]
    fn drop_negotiation_requires_file_format_unlocked_ui_and_copy_effect() {
        assert_eq!(
            negotiate_drop_effect(true, false, 1, DROP_EFFECT_COPY | 2),
            DropNegotiation {
                presentation: DropPresentation::Accepting,
                effect: DROP_EFFECT_COPY,
            }
        );
        assert_eq!(
            negotiate_drop_effect(true, true, 1, DROP_EFFECT_COPY),
            DropNegotiation {
                presentation: DropPresentation::Locked,
                effect: DROP_EFFECT_NONE,
            }
        );
        for negotiation in [
            negotiate_drop_effect(false, false, 1, DROP_EFFECT_COPY),
            negotiate_drop_effect(true, false, 1, 2),
        ] {
            assert_eq!(negotiation.presentation, DropPresentation::Unsupported);
            assert_eq!(negotiation.effect, DROP_EFFECT_NONE);
        }
        assert_eq!(
            negotiate_drop_effect(true, false, 0, DROP_EFFECT_COPY),
            DropNegotiation {
                presentation: DropPresentation::Full,
                effect: DROP_EFFECT_NONE,
            }
        );
        assert_eq!(DropPresentation::default(), DropPresentation::Inactive);
        assert_eq!(drop_effect_after_admission_start(true), DROP_EFFECT_COPY);
        assert_eq!(drop_effect_after_admission_start(false), DROP_EFFECT_NONE);
    }

    #[test]
    fn structured_status_renders_one_priority_message_and_an_independent_count() {
        let mut status = UiStatus::with_recovery("복구 상태를 확인하세요.");
        status.set_transient("2개 경로를 제외했습니다.");
        status.set_progress("파일 변경 중: 3/10 단계");
        status.set_preview_notice(Some("대상 이름 충돌 2개".to_owned()));
        status.set_preview_counts(PreviewCounts {
            total: 120,
            changed: 37,
            selected: 2,
        });

        assert_eq!(status.message_text(), "복구 상태를 확인하세요.");
        assert_eq!(status.count_text(), "전체 120 · 변경 37 · 선택 2");

        status.set_preview_counts(PreviewCounts {
            total: 121,
            changed: 38,
            selected: 3,
        });
        assert_eq!(status.message_text(), "복구 상태를 확인하세요.");
        assert_eq!(status.count_text(), "전체 121 · 변경 38 · 선택 3");

        status.clear_recovery();
        assert_eq!(status.message_text(), "파일 변경 중: 3/10 단계");
        status.clear_progress();
        status.set_preview_sync_failed(true);
        assert_eq!(status.message_text(), PREVIEW_SYNC_FAILURE_STATUS);
        status.set_preview_sync_failed(false);
        assert_eq!(status.message_text(), "대상 이름 충돌 2개");
        status.set_preview_notice(None);
        assert_eq!(status.message_text(), "2개 경로를 제외했습니다.");

        let empty = UiStatus::default();
        assert_eq!(empty.message_text(), EMPTY_LIST_STATUS);
        assert_eq!(empty.count_text(), "전체 0 · 변경 0 · 선택 0");

        let mut promoted = UiStatus::with_transient("일시 상태");
        promoted.set_recovery("복구 상태");
        assert_eq!(promoted.message_text(), "복구 상태");
    }

    #[test]
    fn preview_synchronization_only_authorizes_apply_after_a_confirmed_refresh() {
        let mut synchronization = PreviewSynchronization::default();
        assert!(!synchronization.is_synchronized());

        synchronization.mark_failed();
        assert_eq!(synchronization, PreviewSynchronization::Failed);
        assert!(!synchronization.is_synchronized());

        synchronization.mark_synchronized();
        assert!(synchronization.is_synchronized());

        synchronization.mark_failed();
        assert!(!synchronization.is_synchronized());
    }

    #[test]
    fn workbench_presentation_keeps_apply_authorization_and_empty_state_typed() {
        let changed = PreviewCounts {
            total: 3,
            changed: 2,
            selected: 1,
        };
        assert_eq!(
            UiPresentation::derive(changed, PresentationLocks::default()).apply,
            ApplyPresentation::Ready
        );
        assert_eq!(
            UiPresentation::derive(
                changed,
                PresentationLocks {
                    apply_locked: true,
                    empty_locked: false,
                    worker_active: false,
                }
            )
            .apply,
            ApplyPresentation::Blocked
        );
        assert_eq!(
            UiPresentation::derive(
                changed,
                PresentationLocks {
                    worker_active: true,
                    ..PresentationLocks::default()
                }
            )
            .apply,
            ApplyPresentation::Working
        );

        let empty = PreviewCounts::default();
        assert_eq!(
            UiPresentation::derive(empty, PresentationLocks::default()).empty,
            EmptyStatePresentation::ReadyToAdd
        );
        assert_eq!(
            UiPresentation::derive(
                empty,
                PresentationLocks {
                    empty_locked: true,
                    ..PresentationLocks::default()
                }
            )
            .empty,
            EmptyStatePresentation::Unavailable
        );
        assert_eq!(
            UiPresentation::derive(
                empty,
                PresentationLocks {
                    worker_active: true,
                    ..PresentationLocks::default()
                }
            )
            .empty,
            EmptyStatePresentation::Unavailable
        );
        assert_eq!(
            UiPresentation::derive(changed, PresentationLocks::default()).empty,
            EmptyStatePresentation::Hidden
        );
        assert_eq!(
            UiPresentation::derive(empty, PresentationLocks::default()).apply,
            ApplyPresentation::NoChanges
        );

        assert!(apply_readiness_indicator_visible(
            ApplyPresentation::Ready,
            ForcedColorsState::Inactive,
            true
        ));
        for (apply, forced_colors, rails_visible) in [
            (
                ApplyPresentation::NoChanges,
                ForcedColorsState::Inactive,
                true,
            ),
            (
                ApplyPresentation::Blocked,
                ForcedColorsState::Inactive,
                true,
            ),
            (
                ApplyPresentation::Working,
                ForcedColorsState::Inactive,
                true,
            ),
            (
                ApplyPresentation::Ready,
                ForcedColorsState::ActiveOrUnknown,
                true,
            ),
            (ApplyPresentation::Ready, ForcedColorsState::Inactive, false),
        ] {
            assert!(!apply_readiness_indicator_visible(
                apply,
                forced_colors,
                rails_visible
            ));
        }
    }

    #[test]
    fn proposed_name_visual_preserves_system_selection_and_fail_safe_defaults() {
        let changed = |selected, focused, custom_colors_enabled| {
            proposed_name_visual_decision(ProposedNameVisualContext {
                row: Some(0),
                row_count: 1,
                subitem: 1,
                changed: true,
                issue: PreviewRowIssue::None,
                selected,
                focused,
                custom_colors_enabled,
            })
        };
        assert_eq!(changed(false, false, true), ProposedNameVisual::Changed);
        assert_eq!(changed(true, false, true), ProposedNameVisual::Default);
        assert_eq!(changed(false, true, true), ProposedNameVisual::Changed);
        assert_eq!(changed(false, false, false), ProposedNameVisual::Default);
        assert_eq!(
            ForcedColorsState::from_high_contrast_query(Some(false)),
            ForcedColorsState::Inactive
        );
        for query in [Some(true), None] {
            let state = ForcedColorsState::from_high_contrast_query(query);
            assert_eq!(state, ForcedColorsState::ActiveOrUnknown);
            assert!(!state.custom_colors_enabled());
        }
        assert_eq!(
            proposed_name_visual_decision(ProposedNameVisualContext {
                row: Some(1),
                row_count: 1,
                subitem: 1,
                changed: true,
                issue: PreviewRowIssue::None,
                selected: false,
                focused: false,
                custom_colors_enabled: true,
            }),
            ProposedNameVisual::Default
        );
        assert_eq!(
            proposed_name_visual_decision(ProposedNameVisualContext {
                row: Some(0),
                row_count: 1,
                subitem: 0,
                changed: true,
                issue: PreviewRowIssue::None,
                selected: false,
                focused: false,
                custom_colors_enabled: true,
            }),
            ProposedNameVisual::Default
        );
        assert_eq!(
            proposed_name_visual_decision(ProposedNameVisualContext {
                row: Some(0),
                row_count: 1,
                subitem: 1,
                changed: true,
                issue: PreviewRowIssue::DuplicateDestination,
                selected: false,
                focused: true,
                custom_colors_enabled: true,
            }),
            ProposedNameVisual::Collision
        );
        assert_eq!(
            proposed_name_visual_decision(ProposedNameVisualContext {
                row: Some(0),
                row_count: 1,
                subitem: 1,
                changed: true,
                issue: PreviewRowIssue::InvalidName(darknamer_core::WindowsLeafNameError::Empty,),
                selected: false,
                focused: true,
                custom_colors_enabled: true,
            }),
            ProposedNameVisual::Collision
        );
    }

    #[test]
    fn cancel_control_is_enabled_only_for_an_uncancelled_active_worker() {
        assert_eq!(
            cancel_control_state(WorkerActivity::default()),
            CancelControlState::Hidden
        );
        for activity in [
            WorkerActivity {
                admission: true,
                ..WorkerActivity::default()
            },
            WorkerActivity {
                plan: true,
                ..WorkerActivity::default()
            },
            WorkerActivity {
                apply: true,
                ..WorkerActivity::default()
            },
        ] {
            let state = cancel_control_state(activity);
            assert!(state.is_visible());
            assert!(state.is_enabled());
        }
        assert_eq!(
            active_worker_kind(WorkerActivity {
                admission: true,
                ..WorkerActivity::default()
            }),
            Some(ActiveWorkerKind::Admission)
        );
        assert_eq!(
            active_worker_kind(WorkerActivity {
                plan: true,
                ..WorkerActivity::default()
            }),
            Some(ActiveWorkerKind::Plan)
        );
        assert_eq!(
            active_worker_kind(WorkerActivity {
                apply: true,
                ..WorkerActivity::default()
            }),
            Some(ActiveWorkerKind::Apply)
        );
        assert_eq!(
            active_worker_kind(WorkerActivity {
                admission: true,
                plan: true,
                ..WorkerActivity::default()
            }),
            None
        );
        let requested = cancel_control_state(WorkerActivity {
            apply: true,
            cancellation_requested: true,
            ..WorkerActivity::default()
        });
        assert_eq!(requested, CancelControlState::Requested);
        assert!(requested.is_visible());
        assert!(!requested.is_enabled());
    }

    #[test]
    fn directory_prompt_closes_and_unknown_results_cancel() {
        assert_eq!(
            directory_prompt_choice(DIRECTORY_DIRECT_BUTTON_ID),
            DirectoryPromptChoice::Direct
        );
        assert_eq!(
            directory_prompt_choice(DIRECTORY_RECURSE_BUTTON_ID),
            DirectoryPromptChoice::Recurse
        );
        for result in [0, 1, 2, 6, 7, 42] {
            assert_eq!(
                directory_prompt_choice(result),
                DirectoryPromptChoice::Cancel
            );
        }
    }

    #[test]
    fn destructive_prompt_accepts_only_its_exact_custom_button() {
        assert_eq!(
            destructive_prompt_choice(APPLY_CONFIRM_BUTTON_ID, APPLY_CONFIRM_BUTTON_ID),
            DestructivePromptChoice::Confirm
        );
        assert_eq!(
            destructive_prompt_choice(RECOVER_CONFIRM_BUTTON_ID, RECOVER_CONFIRM_BUTTON_ID),
            DestructivePromptChoice::Confirm
        );
        for result in [
            0,
            1,
            2,
            42,
            DISCARD_CONFIRM_BUTTON_ID,
            RECOVER_CONFIRM_BUTTON_ID,
        ] {
            assert_eq!(
                destructive_prompt_choice(result, APPLY_CONFIRM_BUTTON_ID),
                DestructivePromptChoice::Cancel
            );
        }
        for result in [
            0,
            1,
            2,
            42,
            APPLY_CONFIRM_BUTTON_ID,
            DISCARD_CONFIRM_BUTTON_ID,
        ] {
            assert_eq!(
                destructive_prompt_choice(result, RECOVER_CONFIRM_BUTTON_ID),
                DestructivePromptChoice::Cancel
            );
        }
    }

    #[test]
    fn apply_confirmation_summary_reports_exact_non_authorizing_counts() {
        let summary = ApplyConfirmationSummary {
            logical_changed: 4,
            rename_only: 1,
            move_only: 1,
            move_and_rename: 2,
            common_destination_parent: Some(darknamer_core::LegacyText::from(r"C:\archive")),
            case_only: 1,
            temporary_groups: 2,
            primitive_steps: 6,
        };
        assert_eq!(
            ApplyConfirmationSummary::from_counts(
                1,
                1,
                2,
                Some(darknamer_core::LegacyText::from(r"C:\archive")),
                1,
                6,
            ),
            Some(summary.clone())
        );

        assert_eq!(summary.logical_changed(), 4);
        assert_eq!(summary.case_only(), 1);
        assert_eq!(summary.temporary_groups, 2);
        assert_eq!(summary.cycle_groups(), 1);
        assert_eq!(summary.primitive_steps(), 6);
        let primary = apply_confirmation_primary(summary);
        assert!(primary.contains("논리적 변경: 4개"));
        assert!(primary.contains("대소문자만 변경: 1개"));
        assert!(primary.contains("순환 변경 그룹: 1개"));
        assert!(primary.contains("파일 시스템 변경 단계: 6개"));
        assert!(primary.contains("이름만 변경: 1개"));
        assert!(primary.contains("이동만: 1개"));
        assert!(primary.contains("이동 및 이름 변경: 2개"));
        assert!(primary.contains(r"대상 폴더: C:\archive"));
        assert!(primary.contains("대상 덮어쓰기: 허용하지 않음"));
        assert!(!primary.contains("지문"));
        assert!(!primary.contains("버전"));

        let detail = apply_confirmation_detail(0xA5, 17);
        assert!(detail.contains("00000000000000A5"));
        assert!(detail.contains("목록 버전: 17"));
    }

    #[test]
    fn apply_confirmation_summary_rejects_inconsistent_counts() {
        assert_eq!(
            ApplyConfirmationSummary::from_counts(1, 1, 0, None, 3, 2),
            None
        );
        assert_eq!(
            ApplyConfirmationSummary::from_counts(3, 0, 0, None, 1, 2),
            None
        );
        let root_path = darknamer_core::LegacyText::from(r"C:\a.txt");
        let (parent, leaf) = split_windows_path(&root_path);
        assert_eq!(parent, r"C:\".encode_utf16().collect::<Vec<_>>());
        assert_eq!(leaf, "a.txt".encode_utf16().collect::<Vec<_>>());
    }

    #[test]
    fn apply_confirmation_summary_counts_mixed_direct_cycle_and_case_only_plan()
    -> Result<(), Box<dyn std::error::Error>> {
        use crate::rename::{
            EntryId, EntryKind, MemoryBackend, ModelRevision, PlanRequest, RenameBackend,
            RenameIntent, RenamePlanner, preflight_plan,
        };

        let mut backend = MemoryBackend::new()
            .with_file("C:\\work\\a.txt", 1)
            .with_file("C:\\work\\b.txt", 2)
            .with_file("C:\\work\\c.txt", 3)
            .with_file("C:\\work\\D.TXT", 4);
        let intent = |id, source, destination| {
            RenameIntent::new(
                EntryId::new(id),
                format!("C:\\work\\{source}"),
                "C:\\work",
                destination,
                EntryKind::File,
            )
        };
        let plan = RenamePlanner::new(&backend).plan(PlanRequest::new(
            ModelRevision::new(7),
            vec![
                intent(0, "a.txt", "x.txt"),
                intent(1, "b.txt", "c.txt"),
                intent(2, "c.txt", "b.txt"),
                intent(3, "D.TXT", "d.txt"),
            ],
        ))?;
        let requirements = preflight_plan(&plan, &mut backend)?;
        let summary = ApplyConfirmationSummary::from_plan(
            &plan,
            requirements.primitive_steps(),
            |source, destination| backend.path_key(source) == backend.path_key(destination),
        );

        assert_eq!(
            summary,
            Some(ApplyConfirmationSummary {
                logical_changed: 4,
                rename_only: 4,
                move_only: 0,
                move_and_rename: 0,
                common_destination_parent: Some(darknamer_core::LegacyText::from(r"C:\work")),
                case_only: 1,
                temporary_groups: 2,
                primitive_steps: 6,
            })
        );
        Ok(())
    }

    #[test]
    fn apply_confirmation_summary_derives_move_kinds_and_hides_a_mixed_target_parent()
    -> Result<(), Box<dyn std::error::Error>> {
        use crate::rename::{
            EntryId, EntryKind, MemoryBackend, ModelRevision, MoveScope, PlanRequest,
            RenameBackend, RenameIntent, RenamePlanner, preflight_plan,
        };

        let mut backend = MemoryBackend::new()
            .with_file(r"C:\source\a.txt", 1)
            .with_file(r"C:\source\b.txt", 2)
            .with_file(r"C:\source\c.txt", 3);
        let plan = RenamePlanner::new(&backend).plan(PlanRequest::with_scope(
            ModelRevision::new(8),
            vec![
                RenameIntent::new(
                    EntryId::new(0),
                    r"C:\source\a.txt",
                    r"C:\archive",
                    "a.txt",
                    EntryKind::File,
                ),
                RenameIntent::new(
                    EntryId::new(1),
                    r"C:\source\b.txt",
                    r"C:\archive",
                    "renamed.txt",
                    EntryKind::File,
                ),
                RenameIntent::new(
                    EntryId::new(2),
                    r"C:\source\c.txt",
                    r"C:\source",
                    "local.txt",
                    EntryKind::File,
                ),
            ],
            MoveScope::SameVolumeFilesOnly,
        ))?;
        let requirements = preflight_plan(&plan, &mut backend)?;
        let summary = ApplyConfirmationSummary::from_plan(
            &plan,
            requirements.primitive_steps(),
            |source, destination| backend.path_key(source) == backend.path_key(destination),
        )
        .ok_or("summary")?;

        assert_eq!(summary.rename_only, 1);
        assert_eq!(summary.move_only, 1);
        assert_eq!(summary.move_and_rename, 1);
        assert_eq!(summary.common_destination_parent, None);
        let text = apply_confirmation_primary(summary);
        assert!(text.contains("이름만 변경: 1개"));
        assert!(text.contains("이동만: 1개"));
        assert!(text.contains("이동 및 이름 변경: 1개"));
        assert!(!text.contains("대상 폴더:"));
        assert!(text.contains("대상 덮어쓰기: 허용하지 않음"));
        Ok(())
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
        assert_eq!(minimum_content_width_dip(), 553);

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
    fn primary_columns_fill_the_client_budget_at_supported_dpis() {
        for dpi in [96, 120, 144, 192] {
            let client_width = scale_dip(600, dpi);
            let status_width = scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, dpi);
            let widths = allocate_primary_column_widths(
                client_width,
                status_width,
                dpi,
                &default_column_states(),
            );

            assert_eq!(widths.iter().sum::<i32>(), client_width - status_width);
        }
    }

    #[test]
    fn optional_columns_reduce_the_primary_width_budget() {
        let mut columns = default_column_states();
        columns[3].set_visible(true);

        let widths =
            allocate_primary_column_widths(569, NATIVE_STATUS_COLUMN_WIDTH_DIP, 96, &columns);

        assert_eq!(widths, [129, 128, 80]);
        assert_eq!(widths.iter().sum::<i32>(), 569 - 112 - 120);
    }

    #[test]
    fn expanded_actual_status_width_reduces_the_primary_width_budget() {
        let widths = allocate_primary_column_widths(517, 180, 96, &default_column_states());

        assert_eq!(widths, [129, 128, 80]);
        assert_eq!(widths.iter().sum::<i32>(), 517 - 180);
    }

    #[test]
    fn native_status_column_is_runtime_only_outside_seven_column_preferences() {
        assert_eq!(COLUMNS.len(), 7);
        assert_eq!(default_column_states().len(), 7);
        assert_eq!(
            preferences::shown_columns(&default_column_states()).len(),
            4
        );
        assert_eq!(NATIVE_STATUS_COLUMN_INDEX, 7);
        assert_eq!(NATIVE_LIST_COLUMN_COUNT, 8);
        assert_eq!(NATIVE_STATUS_COLUMN.label, "상태");
        assert_eq!(NATIVE_STATUS_COLUMN.default_width, 112);

        let widths = allocate_primary_column_widths(
            449,
            NATIVE_STATUS_COLUMN_WIDTH_DIP,
            96,
            &default_column_states(),
        );
        assert_eq!(widths, [129, 128, 80]);
        assert_eq!(widths.iter().sum::<i32>(), 449 - 112);

        assert_eq!(status_column_width_after_resize(80, 146, 96), 146);
        assert_eq!(status_column_width_after_resize(240, 146, 96), 240);
        assert_eq!(status_column_width_after_resize(480, 292, 192), 240);
    }

    #[test]
    fn narrow_width_keeps_user_resized_columns_and_allows_overflow() {
        let mut columns = default_column_states();
        columns[0].record_user_resize(220, 96);

        let widths =
            allocate_primary_column_widths(300, NATIVE_STATUS_COLUMN_WIDTH_DIP, 96, &columns);

        assert_eq!(widths, [220, 120, 80]);
        assert!(widths.iter().sum::<i32>() > 300 - NATIVE_STATUS_COLUMN_WIDTH_DIP);
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
    fn minimum_track_size_is_clamped_per_axis_to_the_work_area() {
        assert_eq!(
            constrain_minimum_track_size_to_work_area(640, 520, 1_920, 1_040),
            Some(WindowTrackSize {
                width: 640,
                height: 520,
            })
        );
        assert_eq!(
            constrain_minimum_track_size_to_work_area(640, 520, 480, 320),
            Some(WindowTrackSize {
                width: 480,
                height: 320,
            })
        );
        assert_eq!(
            constrain_minimum_track_size_to_work_area(i32::MAX, i32::MAX, 1, 1),
            Some(WindowTrackSize {
                width: 1,
                height: 1,
            })
        );
        for invalid in [
            (0, 520, 480, 320),
            (640, 0, 480, 320),
            (640, 520, 0, 320),
            (640, 520, 480, 0),
        ] {
            assert_eq!(
                constrain_minimum_track_size_to_work_area(
                    invalid.0, invalid.1, invalid.2, invalid.3,
                ),
                None
            );
        }
    }

    #[test]
    fn work_area_clamping_preserves_compact_then_menu_only_with_bounded_children() {
        let measured = MeasuredFontMetrics::default();
        let minimum_height =
            minimum_main_client_height(96, measured, RailDensityPreference::Automatic);
        let normal = WindowTrackSize {
            width: INITIAL_WIDTH,
            height: minimum_height,
        };
        assert_eq!(
            constrain_minimum_track_size_to_work_area(normal.width, normal.height, 1_920, 1_040,),
            Some(normal)
        );
        let compact = calculate_main_layout(
            normal.width,
            normal.height,
            96,
            measured,
            RailDensityPreference::Automatic,
        );
        assert_eq!(compact.rail_mode, RailMode::Compact);

        let constrained = WindowTrackSize {
            width: INITIAL_WIDTH,
            height: minimum_height - 1,
        };
        assert_eq!(
            constrain_minimum_track_size_to_work_area(
                INITIAL_WIDTH,
                minimum_height,
                constrained.width,
                constrained.height,
            ),
            Some(constrained)
        );
        let menu_only = calculate_main_layout(
            constrained.width,
            constrained.height,
            96,
            measured,
            RailDensityPreference::Automatic,
        );
        assert_eq!(menu_only.rail_mode, RailMode::MenuOnly);

        let smallest = calculate_main_layout(1, 1, 96, measured, RailDensityPreference::Automatic);

        for (layout, bounds) in [
            (&compact, normal),
            (&menu_only, constrained),
            (
                &smallest,
                WindowTrackSize {
                    width: 1,
                    height: 1,
                },
            ),
        ] {
            for rect in [
                layout.list,
                layout.status_message,
                layout.status_count,
                layout.cancel,
                layout.empty_instruction,
                layout.empty_safety,
                layout.empty_add,
                layout.drop_overlay,
            ] {
                assert!(rect.x >= 0);
                assert!(rect.y >= 0);
                assert!(rect.width >= 0);
                assert!(rect.height >= 0);
                assert!(rect.x.saturating_add(rect.width) <= bounds.width);
                assert!(rect.bottom() <= bounds.height);
            }
            for placement in layout.left_buttons.iter().chain(&layout.right_buttons) {
                assert!(placement.x >= 0);
                assert!(placement.y >= 0);
                assert!(placement.width >= 0);
                assert!(placement.height >= 0);
                assert!(placement.x.saturating_add(placement.width) <= layout.rail_width);
                assert!(placement.bottom() <= layout.list.height);
            }
        }
    }

    #[test]
    fn native_empty_state_and_menu_copy_are_exact() {
        assert_eq!(
            EMPTY_LIST_STATUS,
            "파일이나 폴더를 끌어 놓거나 Ctrl+O로 추가하세요."
        );
        assert_eq!(
            command_ui_spec(VERSION).map(|spec| spec.menu_label),
            Some("DarkReNamer 정보...")
        );
        assert_eq!(
            COLUMNS.map(|column| column.label),
            [
                "현재 이름",
                "변경 후 이름",
                "대상 폴더",
                "현재 전체 경로",
                "파일 크기",
                "수정 시각",
                "생성 시각",
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
        assert!(command_enabled(UNIFY_PATH, 1, 0));
        assert!(command_enabled(RESET_PATH, 1, 0));
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
