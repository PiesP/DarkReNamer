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
/// Width of each command bar.
pub const TOOLBAR_WIDTH: i32 = 44;
/// Width of each bitmap cell in the original toolbar strips.
pub const TOOLBAR_BITMAP_WIDTH: i32 = 38;
/// Height of each bitmap cell in the original toolbar strips.
pub const TOOLBAR_BITMAP_HEIGHT: i32 = 24;
/// Height of a native toolbar button after the original MFC border padding.
pub const TOOLBAR_BUTTON_HEIGHT: i32 = 30;
/// Thickness of separators between native toolbar command groups.
pub const TOOLBAR_SEPARATOR_SIZE: i32 = 8;
/// Height of the bottom status bar.
pub const STATUS_HEIGHT: i32 = 18;
/// Design coordinate density used by the original Win32 layout.
pub const BASE_DPI: u32 = 96;

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
        label: "현재이름",
        default_width: 150,
    },
    ColumnSpec {
        label: "바꿀이름",
        default_width: 150,
    },
    ColumnSpec {
        label: "파일위치",
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

/// Toolbar command with its visible native button text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ToolSpec {
    pub id: CommandId,
    pub label: &'static str,
}

/// One entry from an original toolbar resource.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolbarItem {
    Command(CommandId),
    Separator,
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

pub const LEFT_TOOLBAR_ITEMS: [ToolbarItem; 13] = [
    ToolbarItem::Command(APPLY),
    ToolbarItem::Separator,
    ToolbarItem::Command(REPLACE),
    ToolbarItem::Command(PREFIX),
    ToolbarItem::Command(SUFFIX),
    ToolbarItem::Separator,
    ToolbarItem::Command(CLEAR_NAME),
    ToolbarItem::Command(DELETE_POSITION),
    ToolbarItem::Command(DELETE_DELIMITED),
    ToolbarItem::Separator,
    ToolbarItem::Command(KEEP_DIGITS),
    ToolbarItem::Command(PAD_DIGITS),
    ToolbarItem::Command(SEQUENCE),
];

pub const RIGHT_TOOLBAR_ITEMS: [ToolbarItem; 13] = [
    ToolbarItem::Command(RESET),
    ToolbarItem::Separator,
    ToolbarItem::Command(CLEAR_LIST),
    ToolbarItem::Command(MANUAL_CHANGE),
    ToolbarItem::Command(SORT),
    ToolbarItem::Separator,
    ToolbarItem::Command(PARENT_PREFIX),
    ToolbarItem::Command(PARENT_SUFFIX),
    ToolbarItem::Command(UNIFY_PATH),
    ToolbarItem::Separator,
    ToolbarItem::Command(EXT_DELETE),
    ToolbarItem::Command(EXT_ADD),
    ToolbarItem::Command(EXT_REPLACE),
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
    fn layout_columns_and_toolbar_order_match_resources() {
        assert_eq!(
            (
                INITIAL_WIDTH,
                INITIAL_HEIGHT,
                TOOLBAR_WIDTH,
                TOOLBAR_BITMAP_WIDTH,
                TOOLBAR_BITMAP_HEIGHT,
                TOOLBAR_BUTTON_HEIGHT,
                TOOLBAR_SEPARATOR_SIZE,
                STATUS_HEIGHT
            ),
            (464, 408, 44, 38, 24, 30, 8, 18)
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
            LEFT_TOOLBAR_ITEMS,
            [
                ToolbarItem::Command(APPLY),
                ToolbarItem::Separator,
                ToolbarItem::Command(REPLACE),
                ToolbarItem::Command(PREFIX),
                ToolbarItem::Command(SUFFIX),
                ToolbarItem::Separator,
                ToolbarItem::Command(CLEAR_NAME),
                ToolbarItem::Command(DELETE_POSITION),
                ToolbarItem::Command(DELETE_DELIMITED),
                ToolbarItem::Separator,
                ToolbarItem::Command(KEEP_DIGITS),
                ToolbarItem::Command(PAD_DIGITS),
                ToolbarItem::Command(SEQUENCE),
            ]
        );
        assert_eq!(
            RIGHT_TOOLBAR_ITEMS,
            [
                ToolbarItem::Command(RESET),
                ToolbarItem::Separator,
                ToolbarItem::Command(CLEAR_LIST),
                ToolbarItem::Command(MANUAL_CHANGE),
                ToolbarItem::Command(SORT),
                ToolbarItem::Separator,
                ToolbarItem::Command(PARENT_PREFIX),
                ToolbarItem::Command(PARENT_SUFFIX),
                ToolbarItem::Command(UNIFY_PATH),
                ToolbarItem::Separator,
                ToolbarItem::Command(EXT_DELETE),
                ToolbarItem::Command(EXT_ADD),
                ToolbarItem::Command(EXT_REPLACE),
            ]
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
