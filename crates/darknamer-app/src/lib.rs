//! Native Win32 shell and stable DarkNamer 08.02.10 UI contract.

#![cfg_attr(not(windows), forbid(unsafe_code))]

/// Bounded filesystem admission for native picker, drop, and path import.
pub mod admission;
#[cfg(any(windows, test))]
mod apply_progress;
// Pure UI responsibilities remain portable and keep their public crate-root paths.
#[cfg(any(windows, test))]
mod appearance_model;
mod command_catalog;
#[cfg(any(windows, test))]
mod focus_navigation;
mod ui_layout;

pub use command_catalog::{
    ADD_FILES, APPLY, CLEAR_LIST, CLEAR_NAME, COMMAND_UI_SPECS, COPY_NAMES, COPY_PATHS,
    CommandEnableRule, CommandId, CommandMutationClass, CommandRailSpec, CommandUiPolicy,
    CommandUiSpec, DELETE_DELIMITED, DELETE_POSITION, DELETE_SELECTED_UI_SPEC, EXT_ADD, EXT_DELETE,
    EXT_REPLACE, IMPORT_NAMES, IMPORT_PATHS, KEEP_DIGITS, LAST_COMMAND, LEFT_RAIL,
    LEGACY_AUXILIARY_SHORTCUTS, LegacyCommandShortcut, LegacyShortcut, LegacyShortcutModifiers,
    LegacyVirtualKey, MANUAL_CHANGE, MOVE_DOWN, MOVE_UP, MenuGroup, MenuPlacement, PAD_DIGITS,
    PARENT_PREFIX, PARENT_SUFFIX, PREFIX, REPLACE, RESET, RESET_PATH, RIGHT_RAIL, RailPlacement,
    RailSide, SAVE_NAMES, SAVE_PATHS, SEQUENCE, SHOW_CREATED, SHOW_FULL_PATH, SHOW_MODIFIED,
    SHOW_SIZE, SORT, SUFFIX, ToolSpec, UNIFY_PATH, VERSION, command_enabled, command_menu_label,
    command_ui_policy, command_ui_spec, legacy_command_shortcut, legacy_command_shortcuts,
    rail_tool_spec, rail_tool_specs,
};
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use command_catalog::{DELETE_SELECTED_COMMAND, EXIT_COMMAND};

#[cfg(any(windows, test))]
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use ui_layout::{AppearanceDialogLayout, PromptLayout, StatusChromeGeometry};
#[cfg(any(windows, test))]
pub(crate) use ui_layout::{
    AppearanceDialogMetrics, ColumnState, LayoutRect, MeasuredFontMetrics,
    NATIVE_LIST_COLUMN_COUNT, NATIVE_STATUS_COLUMN, NATIVE_STATUS_COLUMN_INDEX, PromptFields,
    PromptFontMetrics, RailMode, StatusLayoutInput, WorkspaceChromeGeometry,
    allocate_primary_column_widths, calculate_appearance_dialog_layout,
    calculate_apply_readiness_indicator_rect, calculate_blank_list_body_rect,
    calculate_button_paint_geometry, calculate_command_rail_separator_layout,
    calculate_header_chrome, calculate_main_layout_with_safety, calculate_menu_bottom_edge,
    calculate_prompt_layout, calculate_scrollbar_parts, clamp_appearance_dialog_scroll,
    decorative_separator_line, default_column_states, empty_state_safety_copy,
    main_layout_window_count, minimum_main_client_height_with_safety, minimum_main_client_width,
    recommended_main_client_height_with_safety, scale_system_font_height,
    status_column_width_after_resize,
};
pub use ui_layout::{
    COLUMNS, ColumnSpec, CommandPlacement, LayoutError, RailDensity, RailDensityPreference,
    UiMetrics, calculate_command_rail_layout, scale_dip, select_command_rail_density,
    select_command_rail_density_with_preference,
};
#[cfg(test)]
pub(crate) use ui_layout::{
    calculate_main_layout, minimum_main_client_height, recommended_main_client_height,
};

#[cfg(windows)]
pub(crate) use appearance_model::PREVIEW_DETAILS;
#[cfg(any(windows, test))]
pub(crate) use appearance_model::{
    APPEARANCE_ADVANCED, AppThemeMode, AppearanceDialogAction, AppearanceDialogEffect,
    AppearanceDialogModel, DwmFrameAction, ForcedColorsState, PreviewEmphasis,
    ProposedNameVisualContext, ResolvedTheme, ResolvedUiAppearance, THEME_DARK, THEME_LIGHT,
    THEME_SYSTEM, UiAppearance, advanced_appearance_available, appearance_after_theme_command,
    appearance_command_allowed, appearance_dialog_should_notify_cancel, dwm_frame_action,
    owner_draw_menu_for_theme, pack_ui_appearance, prompt_custom_theme_enabled,
    proposed_name_colors, proposed_name_visual_decision, semantic_palette, theme_command_for_mode,
    theme_from_foreground, unpack_ui_appearance,
};

#[cfg(any(windows, test))]
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use appearance_model::SemanticPalette;

// These crate-root aliases existed before extraction; retain them for internal callers.
#[cfg(any(windows, test))]
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use appearance_model::{ProposedNameColors, ProposedNameVisual, theme_mode_for_command};
#[cfg(any(windows, test))]
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use ui_layout::{ButtonPaintGeometry, HeaderChromeGeometry, MainLayout};
#[cfg(any(windows, test))]
#[allow(unused_imports, reason = "preserve pre-extraction crate-root paths")]
pub(crate) use ui_layout::{adaptive_primary_column_widths, minimum_content_width_px};

#[cfg(any(windows, test))]
pub(crate) use focus_navigation::{FocusAction, FocusChild, FocusState};

#[cfg(test)]
use appearance_model::{GRAPHITE_DARK, PRECISION_LIGHT};
#[cfg(test)]
use ui_layout::{
    calculate_drop_overlay_layout, calculate_empty_state_layout, conservative_wrapped_text_height,
    required_command_rail_height,
};

/// Bounded shell-icon cache key derivation.
pub mod icon_cache;
#[cfg(windows)]
pub(crate) mod icon_requests;
#[cfg(any(windows, test))]
mod preview;
/// Safe rename planning and execution foundation.
pub mod rename;

#[cfg(windows)]
pub(crate) use preview::{
    PreviewCountCache, PreviewCounts, PreviewIssueCache, PreviewRowIssue, preview_item_details,
    preview_status_delta_rows, preview_status_label,
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
pub(crate) const LIST_COLUMN_FIT_GUTTER_DIP: i32 = 1;
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
pub(crate) enum ButtonMnemonicRendering {
    Literal,
    HiddenCue,
    ShownCue,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) fn button_mnemonic_rendering(
    label: &[u16],
    show_keyboard_cues: bool,
) -> ButtonMnemonicRendering {
    if !label.contains(&u16::from(b'&')) {
        ButtonMnemonicRendering::Literal
    } else if show_keyboard_cues {
        ButtonMnemonicRendering::ShownCue
    } else {
        ButtonMnemonicRendering::HiddenCue
    }
}

#[cfg(any(windows, test))]
mod window_placement;
#[cfg(any(windows, test))]
#[allow(unused_imports)]
pub(crate) use window_placement::HorizontalWindowPlacement;
#[cfg(any(windows, test))]
pub(crate) use window_placement::{
    WindowOrigin, WindowPlacement, WindowTrackSize, WorkAreaBounds,
    constrain_minimum_track_size_to_work_area, fit_widened_window_to_work_area,
    fit_window_to_work_area,
};

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
pub(crate) fn apply_confirmation_primary(summary: &ApplyConfirmationSummary) -> String {
    let mut text = if summary.rename_only == summary.logical_changed() {
        format!("파일 {}개의 이름을 변경합니다.", summary.logical_changed())
    } else if summary.move_only == summary.logical_changed() {
        format!("파일 {}개를 이동합니다.", summary.logical_changed())
    } else if summary.move_and_rename == summary.logical_changed() {
        format!(
            "파일 {}개를 이동하고 이름도 변경합니다.",
            summary.logical_changed()
        )
    } else {
        format!(
            "파일 {}개의 이름 또는 대상 폴더를 변경합니다.",
            summary.logical_changed()
        )
    };
    let kind_count = usize::from(summary.rename_only != 0)
        .saturating_add(usize::from(summary.move_only != 0))
        .saturating_add(usize::from(summary.move_and_rename != 0));
    if kind_count > 1 && summary.rename_only != 0 {
        text.push_str(&format!("\n이름 변경: {}개", summary.rename_only));
    }
    if kind_count > 1 && summary.move_only != 0 {
        text.push_str(&format!("\n대상 폴더 이동: {}개", summary.move_only));
    }
    if kind_count > 1 && summary.move_and_rename != 0 {
        text.push_str(&format!(
            "\n이름 변경 및 대상 폴더 이동: {}개",
            summary.move_and_rename
        ));
    }
    if summary.move_only != 0 || summary.move_and_rename != 0 {
        if let Some(parent) = &summary.common_destination_parent {
            let parent = parent.to_string_lossy();
            let chars: Vec<char> = parent.chars().collect();
            let snippet = bounded_difference_snippet(&chars, chars.len(), chars.len());
            let label = if snippet == parent {
                "대상 폴더"
            } else {
                "대상 폴더 (축약)"
            };
            text.push_str(&format!("\n{label}: {snippet}"));
        } else {
            text.push_str("\n대상 폴더는 항목별로 확인하세요.");
        }
    }
    text.push_str("\n기존 파일을 덮어쓰지 않습니다.");
    text
}

/// Selection is context for the user, never an input to the frozen Apply plan.
#[cfg(any(windows, test))]
pub(crate) fn apply_confirmation_scope(total: usize, selected: usize, changed: usize) -> String {
    format!(
        "목록 전체 {total}개 · 선택 {selected}개 · 실제 변경 {changed}개\n선택 여부와 관계없이 목록의 변경 예정 항목을 모두 적용합니다."
    )
}

/// Samples at most two immutable plan rows; never traverses the whole list.
#[cfg(any(windows, test))]
pub(crate) fn apply_confirmation_examples(plan: &crate::rename::RenamePlan, full: bool) -> String {
    let shown = plan.rows().len().min(2);
    let mut elided = false;
    let mut comparison_hidden = false;
    let mut text = if full {
        format!("변경 예시 전체 경로 ({shown}/{}개)", plan.rows().len())
    } else {
        format!("변경 예시 ({shown}/{}개)", plan.rows().len())
    };
    for row in plan.rows().iter().take(shown) {
        if full {
            let (_, source_leaf) = split_windows_path(row.source());
            let (_, destination_leaf) = split_windows_path(row.destination());
            text.push_str(&format!(
                "\n\n현재 이름: {}\n변경 후 이름: {}\n현재 전체 경로: {}\n변경 후 전체 경로: {}",
                String::from_utf16_lossy(source_leaf),
                String::from_utf16_lossy(destination_leaf),
                row.source(),
                row.destination()
            ));
        } else {
            let (source_parent, source_leaf) = split_windows_path(row.source());
            let (destination_parent, destination_leaf) = split_windows_path(row.destination());
            let (source, destination) =
                if source_parent != destination_parent || source_leaf == destination_leaf {
                    (
                        row.source().to_string_lossy(),
                        row.destination().to_string_lossy(),
                    )
                } else {
                    (
                        String::from_utf16_lossy(source_leaf),
                        String::from_utf16_lossy(destination_leaf),
                    )
                };
            let (source_snippet, destination_snippet) =
                difference_centered_snippets(&source, &destination);
            elided |= source != source_snippet || destination != destination_snippet;
            comparison_hidden |=
                source_snippet == destination_snippet && row.source() != row.destination();
            text.push_str(&format!(
                "\n\n현재: {source_snippet}\n변경 후: {destination_snippet}"
            ));
        }
    }
    if !full {
        if comparison_hidden {
            text.push_str("\n\n축약문에 차이가 드러나지 않습니다. 전체 정보에서 비교하세요.");
        } else if elided {
            text.push_str("\n\n긴 부분은 …으로 생략합니다.");
        }
        text.push_str("\n전체 이름과 경로: '예시 전체 정보 · 복사'");
    }
    text
}

#[cfg(any(windows, test))]
const APPLY_CONFIRMATION_SNIPPET_CHARS: usize = 56;

/// Keeps the differing region and nearby context visible without changing filename data.
#[cfg(any(windows, test))]
fn difference_centered_snippets(current: &str, after: &str) -> (String, String) {
    let current: Vec<char> = current.chars().collect();
    let after: Vec<char> = after.chars().collect();
    let common_prefix = current
        .iter()
        .zip(&after)
        .take_while(|(left, right)| left == right)
        .count();
    let maximum_suffix = current
        .len()
        .saturating_sub(common_prefix)
        .min(after.len().saturating_sub(common_prefix));
    let common_suffix = current
        .iter()
        .rev()
        .zip(after.iter().rev())
        .take(maximum_suffix)
        .take_while(|(left, right)| left == right)
        .count();

    (
        bounded_difference_snippet(
            &current,
            common_prefix,
            current.len().saturating_sub(common_suffix),
        ),
        bounded_difference_snippet(
            &after,
            common_prefix,
            after.len().saturating_sub(common_suffix),
        ),
    )
}

#[cfg(any(windows, test))]
fn bounded_difference_snippet(chars: &[char], focus_start: usize, focus_end: usize) -> String {
    if chars.len() <= APPLY_CONFIRMATION_SNIPPET_CHARS {
        return chars.iter().collect();
    }

    let focus_start = focus_start.min(chars.len());
    let focus_end = focus_end.clamp(focus_start, chars.len());
    let focus_len = focus_end - focus_start;
    if focus_len.saturating_add(2) <= APPLY_CONFIRMATION_SNIPPET_CHARS {
        let mut available_context = APPLY_CONFIRMATION_SNIPPET_CHARS - focus_len - 2;
        let mut left_context = focus_start.min(available_context / 2);
        let mut right_context = (chars.len() - focus_end).min(available_context - left_context);
        available_context -= left_context + right_context;
        if available_context != 0 {
            let extra_left = (focus_start - left_context).min(available_context);
            left_context += extra_left;
            available_context -= extra_left;
            right_context += (chars.len() - focus_end - right_context).min(available_context);
        }
        let shown_start = focus_start - left_context;
        let shown_end = focus_end + right_context;
        let mut text = String::with_capacity(APPLY_CONFIRMATION_SNIPPET_CHARS);
        if shown_start != 0 {
            text.push('…');
        }
        text.extend(&chars[shown_start..shown_end]);
        if shown_end != chars.len() {
            text.push('…');
        }
        return text;
    }

    let leading_ellipsis = usize::from(focus_start != 0);
    let trailing_ellipsis = usize::from(focus_end != chars.len());
    let visible_focus =
        APPLY_CONFIRMATION_SNIPPET_CHARS.saturating_sub(leading_ellipsis + trailing_ellipsis + 1);
    let leading_focus = visible_focus / 2;
    let trailing_focus = visible_focus - leading_focus;
    let mut text = String::with_capacity(APPLY_CONFIRMATION_SNIPPET_CHARS);
    if leading_ellipsis != 0 {
        text.push('…');
    }
    text.extend(&chars[focus_start..focus_start + leading_focus]);
    text.push('…');
    text.extend(&chars[focus_end - trailing_focus..focus_end]);
    if trailing_ellipsis != 0 {
        text.push('…');
    }
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
pub(crate) fn apply_confirmation_detail(
    summary: &ApplyConfirmationSummary,
    fingerprint: u64,
    revision: u64,
) -> String {
    let mut lines = Vec::new();
    if summary.case_only() != 0 {
        lines.push(format!("대소문자만 변경: {}개", summary.case_only()));
    }
    if summary.cycle_groups() != 0 {
        lines.push(format!("순환 변경 그룹: {}개", summary.cycle_groups()));
    }
    if summary.primitive_steps() != summary.logical_changed() {
        lines.push(format!(
            "파일 시스템 변경 단계: {}개",
            summary.primitive_steps()
        ));
    }
    lines.push(format!("계획 지문: {fingerprint:016X}"));
    lines.push(format!("목록 버전: {revision}"));
    lines.join("\n")
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

/// Structured status content whose independent channels survive row refreshes.
#[cfg(any(windows, test))]
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct UiStatus {
    counts: PreviewCounts,
    transient: Option<String>,
    result: Option<String>,
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
        self.result = None;
        self.transient = Some(message.into());
    }

    pub(crate) fn set_result(&mut self, message: impl Into<String>) {
        self.result = Some(message.into());
    }

    pub(crate) fn set_progress(&mut self, message: impl Into<String>) {
        self.result = None;
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
            .or(self.result.as_deref())
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
    pub(crate) import: bool,
    pub(crate) plan: bool,
    pub(crate) apply: bool,
    pub(crate) cancellation_requested: bool,
    pub(crate) apply_finishing: bool,
}

/// The single worker whose existing cancellation primitive may be requested.
#[cfg(any(windows, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ActiveWorkerKind {
    Admission,
    Import,
    Plan,
    Apply,
}

#[cfg(any(windows, test))]
#[must_use]
pub(crate) const fn active_worker_kind(activity: WorkerActivity) -> Option<ActiveWorkerKind> {
    match (
        activity.admission,
        activity.import,
        activity.plan,
        activity.apply,
    ) {
        (true, false, false, false) => Some(ActiveWorkerKind::Admission),
        (false, true, false, false) => Some(ActiveWorkerKind::Import),
        (false, false, true, false) => Some(ActiveWorkerKind::Plan),
        (false, false, false, true) => Some(ActiveWorkerKind::Apply),
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
    Unavailable,
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
    } else if activity.apply_finishing {
        CancelControlState::Unavailable
    } else if activity.cancellation_requested {
        CancelControlState::Requested
    } else {
        CancelControlState::Enabled
    }
}

#[cfg(any(windows, test))]
#[path = "windows/preferences.rs"]
mod preferences;

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

/// Public product name used by the executable and user-facing diagnostics.
pub const PRODUCT_NAME: &str = "DarkReNamer";
/// Upstream behavior version targeted by compatibility mode.
pub const COMPATIBILITY_TARGET: &str = "DarkNamer 08.02.10";
#[cfg(any(windows, test))]
pub(crate) const ACTIVE_RECOVERY_STATUS_GUIDANCE: &str = "복구 확인을 다시 보려면 앱을 종료한 뒤 다시 실행하세요. 취소해도 파일은 변경되지 않고 복구 잠금을 유지합니다.";

/// Returns the product identity shown by the native About command.
#[must_use]
pub fn about_text() -> String {
    format!(
        "{PRODUCT_NAME} {}\n호환 대상: {COMPATIBILITY_TARGET}\n비공식 커뮤니티 관리 Rust 포트",
        env!("CARGO_PKG_VERSION")
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
    fn button_mnemonic_rendering_processes_prefixes_and_escaped_ampersands() {
        for label in ["전체 복사(&C)", "Save && Close"] {
            let label = label.encode_utf16().collect::<Vec<_>>();
            assert_eq!(
                button_mnemonic_rendering(&label, true),
                ButtonMnemonicRendering::ShownCue
            );
            assert_eq!(
                button_mnemonic_rendering(&label, false),
                ButtonMnemonicRendering::HiddenCue
            );
        }

        let plain = "닫기".encode_utf16().collect::<Vec<_>>();
        assert_eq!(
            button_mnemonic_rendering(&plain, true),
            ButtonMnemonicRendering::Literal
        );
        assert_eq!(
            button_mnemonic_rendering(&plain, false),
            ButtonMnemonicRendering::Literal
        );
    }

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
            MenuGroup::Transform,
            MenuGroup::Help,
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
            shortcut(MOVE_UP).map(|value| (value.virtual_key, value.modifiers)),
            Some((LegacyVirtualKey::Up, LegacyShortcutModifiers::Alt))
        );
        assert_eq!(
            shortcut(MOVE_DOWN).map(|value| (value.virtual_key, value.modifiers)),
            Some((LegacyVirtualKey::Down, LegacyShortcutModifiers::Alt))
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
    fn active_recovery_status_guidance_explains_how_to_reopen_confirmation() {
        assert!(ACTIVE_RECOVERY_STATUS_GUIDANCE.contains("다시 실행"));
        assert!(ACTIVE_RECOVERY_STATUS_GUIDANCE.contains("취소"));
        assert!(ACTIVE_RECOVERY_STATUS_GUIDANCE.contains("파일은 변경되지 않"));
        assert!(ACTIVE_RECOVERY_STATUS_GUIDANCE.contains("복구 잠금"));
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
    fn system_text_scale_factor_scales_logfont_height_once() {
        assert_eq!(scale_system_font_height(-12, 1.0), -12);
        assert_eq!(scale_system_font_height(-12, 1.5), -18);
        assert_eq!(scale_system_font_height(-12, 2.25), -27);
        assert_eq!(scale_system_font_height(-13, 1.25), -16);
        assert_eq!(scale_system_font_height(-13, 1.5), -20);
        assert_eq!(scale_system_font_height(scale_dip(-12, 144), 1.5), -27);
    }

    #[test]
    fn invalid_system_text_scale_factor_preserves_font_height() {
        for factor in [f64::NAN, f64::NEG_INFINITY, 0.0, 0.99, 2.26, f64::INFINITY] {
            assert_eq!(scale_system_font_height(-12, factor), -12);
        }
        assert_eq!(scale_system_font_height(i32::MAX, 2.25), i32::MAX);
        assert_eq!(scale_system_font_height(i32::MIN, 2.25), i32::MIN);
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
        for start in [1, 4, 7] {
            assert_eq!(
                right[start].y - right[start - 1].bottom(),
                metrics.group_gap
            );
        }
        Ok(())
    }

    #[test]
    fn painting_roles_keep_physical_hairlines_and_scale_focus_and_press() {
        for dpi in [96, 120, 144, 192] {
            let rect = LayoutRect {
                x: 4,
                y: 8,
                width: scale_dip(64, dpi),
                height: scale_dip(40, dpi),
            };
            let first = calculate_button_paint_geometry(rect, dpi, false);
            let next = calculate_button_paint_geometry(rect, dpi, true);
            assert_eq!(first.outline[0].height, 1);
            assert_eq!(first.outline[1].width, 1);
            assert_eq!(first.outline[2].height, 1);
            assert_eq!(first.outline[3].width, 1);
            assert_eq!(next.outline[0].height, 0);
            assert_eq!(&next.outline[1..], &first.outline[1..]);
            assert_eq!(
                first
                    .focus
                    .map(|focus| (focus.x - rect.x, focus.y - rect.y)),
                Some((scale_dip(3, dpi), scale_dip(3, dpi)))
            );
            assert_eq!(first.pressed_offset, scale_dip(1, dpi));
            assert_eq!(first.default_outline.map(|inner| inner.x - rect.x), Some(1));
            let slot = LayoutRect {
                height: scale_dip(2, dpi),
                ..rect
            };
            let line = decorative_separator_line(slot);
            assert_eq!(line.height, 1);
            assert!(line.y >= slot.y && line.bottom() <= slot.bottom());
        }
        for width in [0, 1, 2, 3] {
            for height in [0, 1, 2, 3] {
                let rect = LayoutRect {
                    x: 0,
                    y: 0,
                    width,
                    height,
                };
                let geometry = calculate_button_paint_geometry(rect, 192, false);
                assert!(geometry.focus.is_none());
                for edge in geometry.outline {
                    assert!(edge.width >= 0 && edge.height >= 0);
                    assert!(edge.right() <= width && edge.bottom() <= height);
                }
            }
        }
    }

    #[test]
    fn native_scrollbar_parts_remain_inside_the_native_rectangle() {
        for vertical in [false, true] {
            for dpi in [96, 120, 144, 192] {
                let thickness = scale_dip(17, dpi);
                let length = scale_dip(200, dpi);
                let bar = LayoutRect {
                    x: 7,
                    y: 11,
                    width: if vertical { thickness } else { length },
                    height: if vertical { length } else { thickness },
                };
                let parts =
                    calculate_scrollbar_parts(bar, vertical, thickness, thickness + 5, length / 2);
                assert!(parts.is_some());
                for part in parts.into_iter().flatten() {
                    assert!(part.x >= bar.x && part.y >= bar.y);
                    assert!(part.right() <= bar.right() && part.bottom() <= bar.bottom());
                }
                assert_eq!(
                    calculate_scrollbar_parts(bar, vertical, thickness, -1, 10),
                    None
                );
                assert_eq!(
                    calculate_scrollbar_parts(bar, vertical, thickness, 10, length + 1),
                    None
                );
            }
        }
    }

    #[test]
    fn blank_list_body_never_covers_header_rows_or_nonclient_scrollbars() {
        let client = LayoutRect {
            x: 0,
            y: 0,
            width: 400,
            height: 250,
        };
        for (header, last, expected_top) in [(24, 0, 24), (31, 50, 50), (48, -40, 48)] {
            let body = calculate_blank_list_body_rect(client, header, last);
            assert_eq!(
                body,
                Some(LayoutRect {
                    x: 0,
                    y: expected_top,
                    width: 400,
                    height: 250 - expected_top
                })
            );
        }
        assert_eq!(calculate_blank_list_body_rect(client, 24, 250), None);
        assert_eq!(calculate_blank_list_body_rect(client, 24, 500), None);
        assert_eq!(
            calculate_blank_list_body_rect(LayoutRect { width: 0, ..client }, 24, 40),
            None
        );
        assert_eq!(
            calculate_blank_list_body_rect(
                LayoutRect {
                    height: 0,
                    ..client
                },
                24,
                40
            ),
            None
        );
    }

    #[test]
    fn decorative_dividers_are_quieter_than_controls_and_disabled_text_is_distinct() {
        let luma = |color: u32| {
            (color & 255) * 2126 + ((color >> 8) & 255) * 7152 + ((color >> 16) & 255) * 722
        };
        for palette in [PRECISION_LIGHT, GRAPHITE_DARK] {
            let surface = luma(palette.surface_window);
            assert!(
                surface.abs_diff(luma(palette.control_outline))
                    > surface.abs_diff(luma(palette.divider_subtle))
            );
            assert!(
                luma(palette.text_disabled).abs_diff(luma(palette.control_disabled))
                    > surface.abs_diff(luma(palette.control_outline))
            );
            assert_ne!(palette.text_disabled, palette.text_primary);
            assert_ne!(palette.text_disabled, palette.text_secondary);
        }
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
            Some("제안명\n초기화")
        );
        let reset = command_ui_spec(RESET).expect("name reset command");
        assert_eq!(reset.menu_label, "제안 이름 초기화");
        assert_eq!(reset.rail_spoken_label(), "제안명 초기화");
        assert!(reset.tooltip_label.contains("제안 이름"));
        assert!(reset.tooltip_label.contains("대상 폴더 변경은 유지"));
        assert!(
            reset
                .tooltip_label
                .contains("완료된 파일 작업은 취소하지 않습니다")
        );
    }

    #[test]
    fn name_reset_keeps_a_separate_destination_proposal_and_is_model_only() {
        use darknamer_core::{LegacyList, LegacyListItem, LegacyText};

        let mut list = LegacyList::new();
        assert_eq!(
            list.append(LegacyListItem::new(r"C:\work\original.txt", false, 0, 0, 0)),
            Ok(true)
        );
        assert_eq!(
            list.unify_destination_parent_changed(&LegacyText::from(r"C:\target"))
                .map(|rows| rows.into_vec()),
            Ok(vec![0])
        );
        assert_eq!(list.manual_change_changed(0, "draft.txt"), Ok(true));
        assert_eq!(
            list.reset_proposals_changed().map(|rows| rows.into_vec()),
            Ok(vec![0])
        );
        let row = &list.items()[0];
        assert_eq!(
            row.source_path(),
            &LegacyText::from(r"C:\work\original.txt")
        );
        assert_eq!(row.proposed_name(), row.current_name());
        assert_eq!(row.destination_parent(), &LegacyText::from(r"C:\target"));
        assert_eq!(
            row.planned_path(),
            LegacyText::from(r"C:\target\original.txt")
        );
        assert_eq!(
            command_ui_spec(RESET).map(|spec| (spec.mutation, spec.display)),
            Some((CommandMutationClass::Model, CommandUiPolicy::AllRows))
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
    fn menu_rendering_policy_tracks_resolved_theme_transitions() {
        let mut appearance = UiAppearance {
            theme: AppThemeMode::Dark,
            ..UiAppearance::default()
        };
        let dark = appearance.resolve(ForcedColorsState::Inactive, None);
        assert!(owner_draw_menu_for_theme(dark.theme));

        appearance.theme = AppThemeMode::Light;
        let light = appearance.resolve(ForcedColorsState::Inactive, None);
        assert!(owner_draw_menu_for_theme(light.theme));

        let forced = appearance.resolve(ForcedColorsState::ActiveOrUnknown, None);
        assert!(!owner_draw_menu_for_theme(forced.theme));

        appearance.theme = AppThemeMode::System;
        let unavailable = appearance.resolve(ForcedColorsState::Inactive, None);
        assert!(!owner_draw_menu_for_theme(unavailable.theme));

        appearance.theme = AppThemeMode::Dark;
        let restored = appearance.resolve(ForcedColorsState::Inactive, None);
        assert!(owner_draw_menu_for_theme(restored.theme));
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
    fn planned_change_colors_are_distinct_and_readable_on_preview_surfaces() {
        fn luminance(color: u32) -> f64 {
            let channel = |shift: u32| {
                let value = f64::from((color >> shift) & 255_u32) / 255.0;
                if value <= 0.04045 {
                    value / 12.92
                } else {
                    ((value + 0.055) / 1.055).powf(2.4)
                }
            };
            0.2126 * channel(0) + 0.7152 * channel(8) + 0.0722 * channel(16)
        }

        for palette in [PRECISION_LIGHT, GRAPHITE_DARK] {
            for color in [
                palette.changed_subtle,
                palette.changed_standard,
                palette.changed_strong,
            ] {
                assert_ne!(color, palette.warning);
                assert_ne!(color, palette.collision);
                for background in [palette.surface_workspace, palette.preview_tint] {
                    let text = luminance(color);
                    let surface = luminance(background);
                    let contrast = (text.max(surface) + 0.05) / (text.min(surface) + 0.05);
                    assert!(contrast >= 4.5, "preview text contrast: {contrast}");
                }
            }
            assert_ne!(palette.apply_keyline, palette.collision);
        }
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
        for dpi in [96, 98, 120, 144, 150, 175, 192, 240, 288] {
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
            list_header_height: 0,
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
    fn empty_state_minimum_height_reserves_the_native_header() {
        let without_header = MeasuredFontMetrics {
            empty_instruction_text_width: 240,
            empty_instruction_text_height: 20,
            empty_safety_text_width: 240,
            empty_safety_text_height: 18,
            empty_add_text_width: 112,
            empty_add_text_height: 20,
            ..MeasuredFontMetrics::default()
        };
        let with_header = MeasuredFontMetrics {
            list_header_height: 24,
            ..without_header
        };

        assert_eq!(
            minimum_main_client_height(96, with_header, RailDensityPreference::MenuOnly),
            minimum_main_client_height(96, without_header, RailDensityPreference::MenuOnly) + 24
        );
    }

    #[test]
    fn empty_state_is_centered_in_the_list_data_area() {
        let measured = MeasuredFontMetrics {
            list_header_height: 32,
            empty_instruction_text_width: 180,
            empty_instruction_text_height: 20,
            empty_add_text_width: 112,
            empty_add_text_height: 20,
            ..MeasuredFontMetrics::default()
        };
        let list = LayoutRect {
            x: 10,
            y: 12,
            width: 320,
            height: 240,
        };

        let empty = calculate_empty_state_layout(list, 96, measured, false);
        let content = measured.empty_state_content_metrics(96, empty.instruction.width, false);
        let data_top = list.y + measured.list_header_height;
        let expected_top =
            data_top + (list.height - measured.list_header_height - content.total_height) / 2;

        assert_eq!(empty.instruction.y, expected_top);
        assert!(empty.instruction.y >= data_top);
        assert!(empty.add.bottom() <= list.bottom());
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
                import: true,
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
                import: true,
                ..WorkerActivity::default()
            }),
            Some(ActiveWorkerKind::Import)
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
    fn finished_work_is_visible_until_the_next_action_without_hiding_recovery() {
        let mut status = UiStatus::default();
        status.set_preview_notice(Some("preview warning".into()));
        status.set_result("restored cancellation");
        assert_eq!(status.message_text(), "restored cancellation");
        status.set_recovery("recovery required");
        assert_eq!(status.message_text(), "recovery required");
        status.clear_recovery();
        status.set_preview_sync_failed(true);
        assert_eq!(status.message_text(), PREVIEW_SYNC_FAILURE_STATUS);
        status.set_preview_sync_failed(false);
        status.set_transient("edited preview");
        assert_eq!(status.message_text(), "preview warning");
        status.set_preview_notice(None);
        assert_eq!(status.message_text(), "edited preview");
        status.set_result("completed");
        status.set_progress("planning");
        status.clear_progress();
        assert_eq!(status.message_text(), "edited preview");
    }

    #[test]
    fn rollback_and_terminal_handoff_do_not_offer_cancellation() {
        for requested in [false, true] {
            let control = cancel_control_state(WorkerActivity {
                apply: true,
                apply_finishing: true,
                cancellation_requested: requested,
                ..WorkerActivity::default()
            });
            assert_eq!(control, CancelControlState::Unavailable);
            assert!(control.is_visible());
            assert!(!control.is_enabled());
        }
    }

    #[test]
    fn apply_scope_distinguishes_selection_from_all_changed_rows() {
        for selected in [0, 1, 10] {
            let scope = apply_confirmation_scope(10, selected, 7);
            assert!(scope.contains("목록 전체 10개"));
            assert!(scope.contains(&format!("선택 {selected}개")));
            assert!(scope.contains("실제 변경 7개"));
            assert!(scope.contains("변경 예정 항목을 모두 적용"));
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

    fn confirmation_plan(
        pairs: &[(String, String)],
    ) -> Result<crate::rename::RenamePlan, crate::rename::PlanError> {
        use crate::rename::{
            EntryId, EntryKind, MemoryBackend, ModelRevision, MoveScope, PlanRequest, RenameIntent,
            RenamePlanner,
        };

        let mut backend = MemoryBackend::new();
        for (index, (source, _)) in pairs.iter().enumerate() {
            backend = backend.with_file(source.as_str(), index as u128 + 1);
        }
        let intents = pairs
            .iter()
            .enumerate()
            .map(|(index, (source, destination))| {
                let destination = darknamer_core::LegacyText::from(destination.as_str());
                let (parent, leaf) = split_windows_path(&destination);
                RenameIntent::new(
                    EntryId::new(index as u32),
                    source.as_str(),
                    darknamer_core::LegacyText::from_units(parent.to_vec()),
                    darknamer_core::LegacyText::from_units(leaf.to_vec()),
                    EntryKind::File,
                )
            })
            .collect();
        RenamePlanner::new(&backend).plan(PlanRequest::with_scope(
            ModelRevision::new(1),
            intents,
            MoveScope::SameVolumeFilesOnly,
        ))
    }

    #[test]
    fn confirmation_repeated_insertions_disclose_identical_snippets()
    -> Result<(), Box<dyn std::error::Error>> {
        confirmation_repeated_change_discloses_identical_snippets(100, 101)
    }

    #[test]
    fn confirmation_repeated_deletions_disclose_identical_snippets()
    -> Result<(), Box<dyn std::error::Error>> {
        confirmation_repeated_change_discloses_identical_snippets(101, 100)
    }

    fn confirmation_repeated_change_discloses_identical_snippets(
        before_count: usize,
        after_count: usize,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let mut undisclosed = Vec::new();
        for repeated in ["a", "가", "0", "𠮷"] {
            let before = format!("{}.txt", repeated.repeat(before_count));
            let after = format!("{}.txt", repeated.repeat(after_count));
            let (left, right) = difference_centered_snippets(&before, &after);
            assert_eq!(left, right, "fixture must exercise the rendering collision");
            assert!(left.chars().count() <= APPLY_CONFIRMATION_SNIPPET_CHARS);
            let source = format!(r"C:\work\{before}");
            let destination = format!(r"C:\work\{after}");
            let plan = confirmation_plan(&[(source.clone(), destination.clone())])?;
            let examples = apply_confirmation_examples(&plan, false);
            if !examples.contains("축약문에 차이가 드러나지 않습니다") {
                undisclosed.push(format!(
                    "{repeated} {before_count}->{after_count}: {examples}"
                ));
            }
            let full = apply_confirmation_examples(&plan, true);
            assert!(full.contains(&source));
            assert!(full.contains(&destination));
            assert_eq!(plan.rows()[0].source().to_string_lossy(), source);
            assert_eq!(plan.rows()[0].destination().to_string_lossy(), destination);
        }
        assert!(undisclosed.is_empty(), "{}", undisclosed.join("\n\n"));
        Ok(())
    }

    #[test]
    fn confirmation_move_kinds_show_bounded_destination_context()
    -> Result<(), Box<dyn std::error::Error>> {
        for (before, after, moves) in [
            (r"C:\fixture\A\old.txt", r"C:\fixture\A\new.txt", false),
            (r"C:\fixture\A\old.txt", r"C:\fixture\B\old.txt", true),
            (r"C:\fixture\A\old.txt", r"C:\fixture\B\new.txt", true),
        ] {
            let plan = confirmation_plan(&[(before.to_owned(), after.to_owned())])?;
            let summary = ApplyConfirmationSummary::from_plan(&plan, 1, |a, b| a == b)
                .ok_or("consistent summary")?;
            let primary = apply_confirmation_primary(&summary);
            assert_eq!(
                primary.contains(r"대상 폴더: C:\fixture\B"),
                moves,
                "{primary}"
            );
            assert_eq!(primary.contains("대상 폴더:"), moves);
            let examples = apply_confirmation_examples(&plan, false);
            if moves {
                assert!(examples.contains(before), "{examples}");
                assert!(examples.contains(after), "{examples}");
            }
        }
        let parent = format!(r"C:\{}\destination", "long-parent\\".repeat(40));
        let summary = ApplyConfirmationSummary::from_counts(
            0,
            0,
            1,
            Some(darknamer_core::LegacyText::from(parent.as_str())),
            0,
            1,
        )
        .ok_or("consistent summary")?;
        let primary = apply_confirmation_primary(&summary);
        assert!(primary.contains("destination"));
        assert!(!primary.contains(&parent));
        assert!(primary.contains('…'));
        Ok(())
    }

    #[test]
    fn confirmation_mixed_move_destinations_retain_each_example_context()
    -> Result<(), Box<dyn std::error::Error>> {
        let plan = confirmation_plan(&[
            (
                r"C:\fixture\A\old.txt".to_owned(),
                r"C:\fixture\B\new.txt".to_owned(),
            ),
            (
                r"C:\fixture\A\second.txt".to_owned(),
                r"C:\fixture\C\renamed.txt".to_owned(),
            ),
            (
                r"C:\fixture\A\local.txt".to_owned(),
                r"C:\fixture\A\local-new.txt".to_owned(),
            ),
        ])?;
        let summary = ApplyConfirmationSummary::from_plan(&plan, 3, |a, b| a == b)
            .ok_or("consistent summary")?;
        assert_eq!(summary.common_destination_parent, None);
        assert!(!apply_confirmation_primary(&summary).contains("대상 폴더:"));
        assert!(apply_confirmation_primary(&summary).contains("대상 폴더는 항목별로 확인하세요."));
        let examples = apply_confirmation_examples(&plan, false);
        assert!(examples.contains(r"C:\fixture\B\new.txt"), "{examples}");
        assert!(examples.contains(r"C:\fixture\C\renamed.txt"), "{examples}");
        assert!(!examples.contains("local-new"));
        Ok(())
    }

    #[test]
    fn confirmation_unsampled_move_keeps_destination_scope_visible()
    -> Result<(), Box<dyn std::error::Error>> {
        let plan = confirmation_plan(&[
            (
                r"C:\fixture\A\first.txt".to_owned(),
                r"C:\fixture\A\first-new.txt".to_owned(),
            ),
            (
                r"C:\fixture\A\second.txt".to_owned(),
                r"C:\fixture\A\second-new.txt".to_owned(),
            ),
            (
                r"C:\fixture\A\third.txt".to_owned(),
                r"C:\fixture\B\third.txt".to_owned(),
            ),
        ])?;
        let summary = ApplyConfirmationSummary::from_plan(&plan, 3, |a, b| a == b)
            .ok_or("consistent summary")?;
        assert_eq!(summary.common_destination_parent, None);
        let primary = apply_confirmation_primary(&summary);
        assert!(primary.contains("대상 폴더 이동: 1개"));
        assert!(
            primary.contains("대상 폴더는 항목별로 확인하세요."),
            "{primary}"
        );
        assert!(!primary.contains("대상 폴더:"));
        assert!(!apply_confirmation_examples(&plan, false).contains("third"));
        assert!(!apply_confirmation_examples(&plan, true).contains("third"));
        Ok(())
    }

    #[test]
    fn confirmation_snippets_keep_suffix_and_extension_differences_visible() {
        let prefix = "긴-공통-접두어-".repeat(8);
        let current = format!("{prefix}일련번호-000001-source.archive");
        let after = format!("{prefix}일련번호-000002-target.webp");
        let (current_snippet, after_snippet) = difference_centered_snippets(&current, &after);

        assert!(current_snippet.starts_with('…'));
        assert!(after_snippet.starts_with('…'));
        assert!(current_snippet.contains("000001-source.archive"));
        assert!(after_snippet.contains("000002-target.webp"));
        assert_ne!(current_snippet, after_snippet);
        assert!(current_snippet.chars().count() <= APPLY_CONFIRMATION_SNIPPET_CHARS);
        assert!(after_snippet.chars().count() <= APPLY_CONFIRMATION_SNIPPET_CHARS);
    }

    #[test]
    fn confirmation_short_names_do_not_claim_elision() -> Result<(), Box<dyn std::error::Error>> {
        let plan =
            confirmation_plan(&[(r"C:\work\old.txt".to_owned(), r"C:\work\new.txt".to_owned())])?;
        let examples = apply_confirmation_examples(&plan, false);
        assert!(examples.contains("현재: old.txt"));
        assert!(examples.contains("변경 후: new.txt"));
        assert!(!examples.contains("생략"));
        assert!(!examples.contains("축약문에 차이가 드러나지 않습니다"));
        Ok(())
    }

    #[test]
    fn confirmation_snippets_preserve_korean_supplementary_and_middle_changes() {
        let shared_start = format!("{}한글-𠮷-", "앞부분".repeat(12));
        let shared_end = format!("-𠮷-{}-끝.dat", "뒷부분".repeat(12));
        let current = format!("{shared_start}가운데-현재{shared_end}");
        let after = format!("{shared_start}가운데-변경{shared_end}");
        let (current_snippet, after_snippet) = difference_centered_snippets(&current, &after);

        assert!(current_snippet.starts_with('…') && current_snippet.ends_with('…'));
        assert!(after_snippet.starts_with('…') && after_snippet.ends_with('…'));
        assert!(current_snippet.contains("현재"));
        assert!(after_snippet.contains("변경"));
        assert!(current_snippet.contains('𠮷'));
        assert!(after_snippet.contains('𠮷'));
        assert!(!current_snippet.contains('\u{FFFD}'));
        assert!(!after_snippet.contains('\u{FFFD}'));
        assert!(current_snippet.chars().count() <= APPLY_CONFIRMATION_SNIPPET_CHARS);
        assert!(after_snippet.chars().count() <= APPLY_CONFIRMATION_SNIPPET_CHARS);
    }

    #[test]
    fn confirmation_examples_distinguish_parent_only_changes()
    -> Result<(), Box<dyn std::error::Error>> {
        let source = format!(r"C:\{}\same-name.txt", "source-parent-".repeat(8));
        let destination = format!(r"C:\{}\same-name.txt", "target-parent-".repeat(8));
        let plan = confirmation_plan(&[(source, destination)])?;
        let examples = apply_confirmation_examples(&plan, false);

        assert!(examples.contains("source-parent-"));
        assert!(examples.contains("target-parent-"));
        assert!(examples.contains("…으로 생략"));
        assert!(examples.contains("'예시 전체 정보 · 복사'"));
        Ok(())
    }

    #[test]
    fn confirmation_examples_bound_sampling_and_keep_full_original_paths()
    -> Result<(), Box<dyn std::error::Error>> {
        let korean_prefix = "긴한글경로".repeat(6);
        let pairs = vec![
            (
                format!(r"C:\work\{korean_prefix}-𠮷-현재-01.txt"),
                format!(r"C:\work\{korean_prefix}-𠮷-변경-01.webp"),
            ),
            (
                format!(r"C:\work\{korean_prefix}-𠮷-현재-02.txt"),
                format!(r"C:\work\{korean_prefix}-𠮷-변경-02.webp"),
            ),
            (
                r"C:\work\third-original.txt".to_owned(),
                r"C:\work\third-after.txt".to_owned(),
            ),
        ];
        let plan = confirmation_plan(&pairs)?;

        let examples = apply_confirmation_examples(&plan, false);
        assert!(examples.contains("변경 예시 (2/3개)"));
        assert_eq!(examples.matches("\n현재: ").count(), 2);
        assert_eq!(examples.matches("\n변경 후: ").count(), 2);
        assert!(!examples.contains("third-original"));
        for line in examples.lines().filter(|line| line.starts_with("현재: ")) {
            assert!(
                line.trim_start_matches("현재: ").chars().count()
                    <= APPLY_CONFIRMATION_SNIPPET_CHARS
            );
        }
        for line in examples
            .lines()
            .filter(|line| line.starts_with("변경 후: "))
        {
            assert!(
                line.trim_start_matches("변경 후: ").chars().count()
                    <= APPLY_CONFIRMATION_SNIPPET_CHARS
            );
        }

        let full = apply_confirmation_examples(&plan, true);
        assert!(full.contains("변경 예시 전체 경로 (2/3개)"));
        for (source, destination) in pairs.iter().take(2) {
            let source_name = source
                .rsplit_once('\\')
                .map_or(source.as_str(), |(_, name)| name);
            let destination_name = destination
                .rsplit_once('\\')
                .map_or(destination.as_str(), |(_, name)| name);
            assert!(full.contains(&format!("현재 이름: {source_name}")));
            assert!(full.contains(&format!("변경 후 이름: {destination_name}")));
            assert!(full.contains(&format!("현재 전체 경로: {source}")));
            assert!(full.contains(&format!("변경 후 전체 경로: {destination}")));
        }
        assert!(!full.contains("third-original"));
        assert!(!full.contains('\u{FFFD}'));
        Ok(())
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
        let primary = apply_confirmation_primary(&summary);
        assert!(primary.contains("파일 4개의 이름 또는 대상 폴더를 변경합니다."));
        assert!(primary.contains("이름 변경: 1개"));
        assert!(primary.contains("대상 폴더 이동: 1개"));
        assert!(primary.contains("이름 변경 및 대상 폴더 이동: 2개"));
        assert!(primary.contains(r"대상 폴더: C:\archive"));
        assert!(primary.contains("기존 파일을 덮어쓰지 않습니다."));
        assert!(!primary.contains("대소문자만 변경"));
        assert!(!primary.contains("순환 변경 그룹"));
        assert!(!primary.contains("파일 시스템 변경 단계"));
        assert!(!primary.contains("지문"));
        assert!(!primary.contains("버전"));

        let detail = apply_confirmation_detail(&summary, 0xA5, 17);
        assert!(detail.contains("대소문자만 변경: 1개"));
        assert!(detail.contains("순환 변경 그룹: 1개"));
        assert!(detail.contains("파일 시스템 변경 단계: 6개"));
        assert!(detail.contains("00000000000000A5"));
        assert!(detail.contains("목록 버전: 17"));
        assert!(!detail.contains("논리적 변경:"));
        assert!(!detail.contains("이름만 변경:"));
        assert!(!detail.contains("이동만:"));
        assert!(!detail.contains("대상 폴더:"));
    }

    #[test]
    fn apply_confirmation_primary_omits_zero_categories_and_execution_diagnostics()
    -> Result<(), Box<dyn std::error::Error>> {
        let summary = ApplyConfirmationSummary::from_counts(
            1,
            0,
            0,
            Some(darknamer_core::LegacyText::from(r"C:\work")),
            0,
            1,
        )
        .ok_or("consistent rename-only summary")?;

        assert_eq!(
            apply_confirmation_primary(&summary),
            "파일 1개의 이름을 변경합니다.\n기존 파일을 덮어쓰지 않습니다."
        );
        assert_eq!(
            apply_confirmation_detail(&summary, 0xA5, 17),
            "계획 지문: 00000000000000A5\n목록 버전: 17"
        );
        Ok(())
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
        let examples = apply_confirmation_examples(&plan, false);
        assert!(examples.contains("현재: a.txt\n변경 후: x.txt"));
        assert!(examples.contains("현재: b.txt\n변경 후: c.txt"));
        assert!(!examples.contains("D.TXT"));
        let full = apply_confirmation_examples(&plan, true);
        assert!(full.contains(r"현재 전체 경로: C:\work\a.txt"));
        assert!(full.contains(r"변경 후 전체 경로: C:\work\x.txt"));
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
        let text = apply_confirmation_primary(&summary);
        assert!(text.contains("이름 변경: 1개"));
        assert!(text.contains("대상 폴더 이동: 1개"));
        assert!(text.contains("이름 변경 및 대상 폴더 이동: 1개"));
        assert!(!text.contains("대상 폴더:"));
        assert!(text.contains("기존 파일을 덮어쓰지 않습니다."));
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
                .label_one
                .zip(expanded.edit_one)
                .is_some_and(|(label, edit)| label.x.saturating_add(label.width) <= edit.x)
        );
        assert!(
            expanded
                .label_two
                .zip(expanded.edit_two)
                .is_some_and(|(label, edit)| label.x.saturating_add(label.width) <= edit.x)
        );
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
        for (dpi, available, expected) in [
            (96, 320, [120, 120, 80]),
            (96, 360, [136, 136, 88]),
            (96, 400, [152, 152, 96]),
            (120, 400, [150, 150, 100]),
            (144, 480, [180, 180, 120]),
            (192, 640, [240, 240, 160]),
            (96, 1_000, [392, 392, 216]),
            (96, 1_003, [393, 393, 217]),
        ] {
            let widths = adaptive_primary_column_widths(available, dpi);
            assert_eq!(widths, expected);
            assert_eq!(widths.iter().sum::<i32>(), available);
        }
    }

    #[test]
    fn adaptive_primary_columns_use_every_pixel_across_dpi_rounding_boundaries() {
        for dpi in [96, 120, 144, 192, 240, 288] {
            let minimum =
                scale_dip(NAME_COLUMN_MINIMUM, dpi) * 2 + scale_dip(LOCATION_COLUMN_MINIMUM, dpi);
            for available in 0..=minimum + 257 {
                let widths = adaptive_primary_column_widths(available, dpi);
                assert!(widths.iter().all(|width| *width >= 0));
                assert_eq!(widths.iter().sum::<i32>(), available, "DPI {dpi}");
                assert!(
                    (widths[0] - widths[1]).abs() <= 1,
                    "DPI {dpi}, available {available}"
                );
                if available >= minimum {
                    assert!(widths[0] >= scale_dip(NAME_COLUMN_MINIMUM, dpi));
                    assert!(widths[1] >= scale_dip(NAME_COLUMN_MINIMUM, dpi));
                    assert!(widths[2] >= scale_dip(LOCATION_COLUMN_MINIMUM, dpi));
                }
            }
        }
    }

    #[test]
    fn automatic_default_columns_preserve_the_exact_budget_near_boundaries() {
        for dpi in [96, 120, 144, 192, 240, 288] {
            let minimum =
                scale_dip(NAME_COLUMN_MINIMUM, dpi) * 2 + scale_dip(LOCATION_COLUMN_MINIMUM, dpi);
            let status_width = scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, dpi);
            let gutter = scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi).max(1);
            for extra in 0..=31 {
                let budget = minimum + extra;
                let widths = allocate_primary_column_widths(
                    budget + status_width + gutter,
                    status_width,
                    dpi,
                    &default_column_states(),
                );
                assert_eq!(widths.iter().sum::<i32>(), budget, "DPI {dpi}");
            }
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
    fn automatic_default_columns_preserve_the_fit_gutter_at_supported_dpis() {
        for dpi in [96, 120, 144, 192, 240, 288] {
            let client_width = scale_dip(600, dpi);
            let status_width = scale_dip(NATIVE_STATUS_COLUMN_WIDTH_DIP, dpi);
            let widths = allocate_primary_column_widths(
                client_width,
                status_width,
                dpi,
                &default_column_states(),
            );

            assert_eq!(
                widths.iter().sum::<i32>(),
                client_width - status_width - scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi)
            );
        }
    }

    #[test]
    fn minimum_content_width_uses_the_measured_status_width() {
        for (dpi, status_width) in [
            (96, 146),
            (98, 149),
            (120, 183),
            (150, 228),
            (175, 266),
            (192, 292),
            (288, 438),
        ] {
            assert_eq!(
                minimum_content_width_px(dpi, status_width),
                RailDensity::Comfortable.metrics(dpi).rail_width * 2
                    + scale_dip(NAME_COLUMN_MINIMUM, dpi) * 2
                    + scale_dip(LOCATION_COLUMN_MINIMUM, dpi)
                    + scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi).max(1)
                    + status_width
            );
        }
    }

    #[test]
    fn minimum_width_budget_fits_selected_density_and_default_columns() {
        for (dpi, status_width) in [
            (96, 146),
            (120, 183),
            (144, 219),
            (192, 261),
            (240, 365),
            (288, 438),
        ] {
            let measured = MeasuredFontMetrics {
                button_text_width: scale_dip(52, dpi),
                ..MeasuredFontMetrics::default()
            };
            for (preference, expected_mode) in [
                (RailDensityPreference::Automatic, RailMode::Comfortable),
                (RailDensityPreference::Comfortable, RailMode::Comfortable),
                (RailDensityPreference::Compact, RailMode::Compact),
                (RailDensityPreference::MenuOnly, RailMode::MenuOnly),
            ] {
                let client_width =
                    minimum_main_client_width(dpi, measured, preference, status_width);
                let client_height = recommended_main_client_height(dpi, measured, preference);
                let layout =
                    calculate_main_layout(client_width, client_height, dpi, measured, preference);
                let columns = allocate_primary_column_widths(
                    layout.list.width,
                    status_width,
                    dpi,
                    &default_column_states(),
                );
                let required_list_width = columns
                    .iter()
                    .sum::<i32>()
                    .saturating_add(status_width)
                    .saturating_add(scale_dip(LIST_COLUMN_FIT_GUTTER_DIP, dpi).max(1));

                assert_eq!(layout.rail_mode, expected_mode, "DPI {dpi}");
                assert!(
                    required_list_width <= layout.list.width,
                    "DPI {dpi} {preference:?}: default columns require {required_list_width}px but the selected layout provides {}px",
                    layout.list.width,
                );
                if dpi == 192 && preference == RailDensityPreference::Automatic {
                    assert_eq!(client_width, 1_161);
                    assert_eq!(layout.list.width, 903);
                }
                if dpi == 192 {
                    let previous_explicit_width = match preference {
                        RailDensityPreference::Automatic => None,
                        RailDensityPreference::Comfortable => Some(1_161),
                        RailDensityPreference::Compact => Some(1_153),
                        RailDensityPreference::MenuOnly => Some(1_111),
                    };
                    if let Some(previous_explicit_width) = previous_explicit_width {
                        assert_eq!(client_width, previous_explicit_width);
                    }
                }
            }

            let automatic_width = minimum_main_client_width(
                dpi,
                measured,
                RailDensityPreference::Automatic,
                status_width,
            );
            let compact_height =
                minimum_main_client_height(dpi, measured, RailDensityPreference::Automatic);
            let compact = calculate_main_layout(
                automatic_width,
                compact_height,
                dpi,
                measured,
                RailDensityPreference::Automatic,
            );
            assert_eq!(compact.rail_mode, RailMode::Compact, "DPI {dpi}");
        }
    }

    #[test]
    fn optional_columns_reduce_the_primary_width_budget() {
        let mut columns = default_column_states();
        columns[3].set_visible(true);

        let widths =
            allocate_primary_column_widths(569, NATIVE_STATUS_COLUMN_WIDTH_DIP, 96, &columns);

        assert_eq!(widths, [127, 127, 83]);
        assert_eq!(widths.iter().sum::<i32>(), 569 - 112 - 120);
    }

    #[test]
    fn expanded_actual_status_width_reduces_the_primary_width_budget() {
        let widths = allocate_primary_column_widths(517, 180, 96, &default_column_states());

        assert_eq!(widths, [127, 126, 83]);
        assert_eq!(
            widths.iter().sum::<i32>(),
            517 - 180 - LIST_COLUMN_FIT_GUTTER_DIP
        );
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
        assert_eq!(widths, [127, 126, 83]);
        assert_eq!(
            widths.iter().sum::<i32>(),
            449 - 112 - LIST_COLUMN_FIT_GUTTER_DIP
        );

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
    fn initial_window_placement_clamps_both_axes_for_offset_work_areas() {
        let fit = |(x, y), (width, height), (left, top, right, bottom)| {
            fit_window_to_work_area(
                WindowOrigin { x, y },
                WindowTrackSize { width, height },
                WorkAreaBounds {
                    left,
                    top,
                    right,
                    bottom,
                },
            )
        };
        assert_eq!(
            fit((1_500, 900), (640, 520), (100, 50, 1_700, 950)),
            Some(WindowPlacement {
                x: 1_060,
                y: 430,
                width: 640,
                height: 520,
            })
        );
        assert_eq!(
            fit((-100, 900), (640, 520), (-1_920, -80, 0, 1_000)),
            Some(WindowPlacement {
                x: -640,
                y: 480,
                width: 640,
                height: 520,
            })
        );
    }

    #[test]
    fn initial_window_placement_handles_exact_and_near_work_area_bounds() {
        let fit = |(x, y), (width, height), (left, top, right, bottom)| {
            fit_window_to_work_area(
                WindowOrigin { x, y },
                WindowTrackSize { width, height },
                WorkAreaBounds {
                    left,
                    top,
                    right,
                    bottom,
                },
            )
        };
        assert_eq!(
            fit((900, 700), (800, 600), (100, 50, 900, 650)),
            Some(WindowPlacement {
                x: 100,
                y: 50,
                width: 800,
                height: 600,
            })
        );
        assert_eq!(
            fit((900, 650), (799, 599), (100, 50, 900, 650)),
            Some(WindowPlacement {
                x: 101,
                y: 51,
                width: 799,
                height: 599,
            })
        );
        assert_eq!(
            fit((0, 0), (801, 601), (100, 50, 900, 650)),
            Some(WindowPlacement {
                x: 100,
                y: 50,
                width: 800,
                height: 600,
            })
        );
        assert_eq!(fit((0, 0), (640, 520), (10, 20, 10, 620)), None);
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
                MANUAL_CHANGE,
                DELETE_SELECTED_COMMAND,
                SORT,
                EXT_DELETE,
                EXT_ADD,
                EXT_REPLACE,
                PARENT_PREFIX,
                PARENT_SUFFIX
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
