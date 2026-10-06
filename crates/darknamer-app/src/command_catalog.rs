#![forbid(unsafe_code)]

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
        self.unordered_command_specs().count()
    }

    /// Iterates over visible command identifiers in display order.
    pub fn commands(self) -> impl Iterator<Item = CommandId> {
        self.command_specs().map(|spec| spec.id)
    }

    /// Iterates over the catalog entries visible on this rail.
    pub fn command_specs(self) -> impl Iterator<Item = &'static CommandUiSpec> {
        self.ordered_command_specs().into_iter()
    }

    fn unordered_command_specs(self) -> impl Iterator<Item = &'static CommandUiSpec> {
        COMMAND_UI_SPECS
            .iter()
            .chain(core::iter::once(&DELETE_SELECTED_UI_SPEC))
            .filter(move |spec| {
                spec.rail
                    .is_some_and(|placement| placement.side == self.side)
            })
    }

    pub(super) fn ordered_command_specs(self) -> Vec<&'static CommandUiSpec> {
        let mut specs = self.unordered_command_specs().collect::<Vec<_>>();
        specs.sort_by_key(|spec| {
            spec.rail.map_or((u8::MAX, u8::MAX), |placement| {
                (placement.group, placement.order)
            })
        });
        specs
    }

    pub(super) fn group_count(self) -> usize {
        let mut groups = [false; 256];
        for spec in self.unordered_command_specs() {
            if let Some(placement) = spec.rail {
                groups[usize::from(placement.group)] = true;
            }
        }
        groups.into_iter().filter(|present| *present).count()
    }
}

/// Explicit left-side command grouping.
pub const LEFT_RAIL: CommandRailSpec = CommandRailSpec {
    side: RailSide::Left,
};
/// Explicit right-side command grouping.
pub const RIGHT_RAIL: CommandRailSpec = CommandRailSpec {
    side: RailSide::Right,
};

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
    Transform,
    Help,
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
    F2,
    Up,
    Down,
    OemComma,
    OemPeriod,
}

/// Modifier combinations used by legacy compatibility accelerators.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LegacyShortcutModifiers {
    None,
    Alt,
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
        menu(MenuGroup::Transform, 0, 0),
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
        menu(MenuGroup::Transform, 0, 1),
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
        menu(MenuGroup::Transform, 0, 2),
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
        menu(MenuGroup::Transform, 1, 0),
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
        menu(MenuGroup::Transform, 1, 1),
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
        menu(MenuGroup::Transform, 1, 2),
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
        menu(MenuGroup::Transform, 2, 0),
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
        menu(MenuGroup::Transform, 2, 1),
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
        menu(MenuGroup::Transform, 2, 2),
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
        "제안명\n초기화",
        menu(MenuGroup::Edit, 2, 0),
        "제안 이름 초기화",
        "모든 제안 이름을 현재 이름으로 되돌립니다. 대상 폴더 변경은 유지되며, 완료된 파일 작업은 취소하지 않습니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_LIST,
        None,
        "목록\n지우기",
        menu(MenuGroup::Edit, 3, 0),
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
        rail(RailSide::Right, 1, 0),
        "직접\n바꾸기",
        menu(MenuGroup::Edit, 0, 0),
        "선택 항목 이름 직접 변경...",
        "선택한 한 항목의 제안 이름을 직접 변경합니다.",
        legacy(LegacyVirtualKey::F2, LegacyShortcutModifiers::None, "F2"),
        Selection,
        Model,
        SingleRow
    ),
    command_ui_spec!(
        SORT,
        rail(RailSide::Right, 1, 2),
        "목록\n정렬",
        menu(MenuGroup::Edit, 1, 2),
        "목록 정렬...",
        "선택한 기준으로 목록 순서를 정렬합니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_PREFIX,
        rail(RailSide::Right, 3, 0),
        "폴더명\n앞에",
        menu(MenuGroup::Transform, 4, 0),
        "대상 폴더명을 이름 앞에 붙이기",
        "제안된 대상 폴더의 마지막 이름을 밑줄과 함께 파일 이름 앞에 붙입니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_SUFFIX,
        rail(RailSide::Right, 3, 1),
        "폴더명\n뒤에",
        menu(MenuGroup::Transform, 4, 1),
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
        menu(MenuGroup::Edit, 2, 1),
        "모든 파일의 대상 폴더 지정...",
        "목록의 모든 일반 파일을 선택한 기존 폴더로 이동하도록 예약합니다. 적용 전에는 실제 파일을 이동하지 않습니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_DELETE,
        rail(RailSide::Right, 2, 0),
        "확장자\n지우기",
        menu(MenuGroup::Transform, 3, 0),
        "확장자 지우기",
        "파일 이름의 확장자를 지웁니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_ADD,
        rail(RailSide::Right, 2, 1),
        "확장자\n추가",
        menu(MenuGroup::Transform, 3, 1),
        "확장자 추가...",
        "파일 이름에 확장자를 추가합니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_REPLACE,
        rail(RailSide::Right, 2, 2),
        "확장자\n변경",
        menu(MenuGroup::Transform, 3, 2),
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
        "모든 항목의 변경 후 이름을 새 텍스트 파일로 저장합니다. 기존 파일은 덮어쓰지 않습니다.",
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
        "모든 항목의 현재 실제 경로를 새 텍스트 파일로 저장합니다. 기존 파일은 덮어쓰지 않습니다.",
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
        menu(MenuGroup::Edit, 1, 0),
        "목록 순서 위로",
        "선택 항목을 목록 순서에서 한 칸 위로 이동합니다.",
        legacy(LegacyVirtualKey::Up, LegacyShortcutModifiers::Alt, "Alt+↑"),
        Selection,
        Model,
        MovedRows
    ),
    command_ui_spec!(
        MOVE_DOWN,
        None,
        "아래로 내림",
        menu(MenuGroup::Edit, 1, 1),
        "목록 순서 아래로",
        "선택 항목을 목록 순서에서 한 칸 아래로 이동합니다.",
        legacy(
            LegacyVirtualKey::Down,
            LegacyShortcutModifiers::Alt,
            "Alt+↓"
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
        menu(MenuGroup::Help, 0, 0),
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
        menu(MenuGroup::Edit, 2, 2),
        "대상 폴더 미리보기 초기화",
        "각 파일의 대상 폴더를 현재 폴더로 되돌립니다. 제안 이름은 유지되며, 완료된 파일 작업은 취소하지 않습니다.",
        None,
        Rows,
        Model,
        AllRows
    ),
];

pub const DELETE_SELECTED_UI_SPEC: CommandUiSpec = command_ui_spec!(
    DELETE_SELECTED_COMMAND,
    rail(RailSide::Right, 1, 1),
    "선택\n제거",
    menu(MenuGroup::Edit, 0, 1),
    "선택 항목을 목록에서 제거",
    "선택한 항목을 목록에서만 제거합니다. 실제 파일은 삭제하지 않습니다.",
    legacy(
        LegacyVirtualKey::Delete,
        LegacyShortcutModifiers::None,
        "Delete"
    ),
    Selection,
    Model,
    AllRows
);

/// Legacy shell accelerators whose commands are outside APPLY..LAST_COMMAND.
pub const LEGACY_AUXILIARY_SHORTCUTS: [LegacyCommandShortcut; 0] = [];

/// Iterates every catalog and auxiliary legacy compatibility accelerator.
pub fn legacy_command_shortcuts() -> impl Iterator<Item = LegacyCommandShortcut> {
    COMMAND_UI_SPECS
        .iter()
        .chain(core::iter::once(&DELETE_SELECTED_UI_SPEC))
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
    if id == DELETE_SELECTED_COMMAND {
        return Some(&DELETE_SELECTED_UI_SPEC);
    }
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
