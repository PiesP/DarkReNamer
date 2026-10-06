#![forbid(unsafe_code)]

use crate::preview::PreviewRowIssue;
use crate::ui_layout::RailDensityPreference;

/// Persisted application theme preference.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum AppThemeMode {
    #[default]
    System,
    Light,
    Dark,
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

/// Whether the resolved theme uses the app-owned menu palette.
#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn owner_draw_menu_for_theme(theme: ResolvedTheme) -> bool {
    matches!(theme, ResolvedTheme::Light | ResolvedTheme::Dark)
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
    pub(crate) control_outline: u32,
    pub(crate) divider_subtle: u32,
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
pub(super) const PRECISION_LIGHT: SemanticPalette = SemanticPalette {
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
    text_disabled: color_ref(110, 117, 127),
    control_outline: color_ref(177, 183, 192),
    divider_subtle: color_ref(217, 221, 227),
    changed_subtle: color_ref(67, 86, 119),
    changed_standard: color_ref(35, 83, 151),
    changed_strong: color_ref(14, 67, 143),
    warning: color_ref(142, 83, 0),
    collision: color_ref(169, 22, 33),
    preview_tint: color_ref(245, 248, 255),
    apply_keyline: color_ref(35, 83, 151),
};

#[cfg(any(windows, test))]
pub(super) const GRAPHITE_DARK: SemanticPalette = SemanticPalette {
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
    text_disabled: color_ref(150, 157, 167),
    control_outline: color_ref(83, 89, 99),
    divider_subtle: color_ref(55, 60, 67),
    changed_subtle: color_ref(167, 184, 210),
    changed_standard: color_ref(133, 183, 255),
    changed_strong: color_ref(174, 208, 255),
    warning: color_ref(255, 194, 92),
    collision: color_ref(255, 137, 145),
    preview_tint: color_ref(32, 40, 51),
    apply_keyline: color_ref(133, 183, 255),
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

/// Read-only preview details, outside the legacy transformation catalog.
#[cfg(windows)]
pub(crate) const PREVIEW_DETAILS: u16 = 0x9014;

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
