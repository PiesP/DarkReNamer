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
        self.ordered_command_specs().len()
    }

    /// Iterates over visible command identifiers in display order.
    pub fn commands(self) -> impl Iterator<Item = CommandId> {
        self.command_specs().map(|spec| spec.id)
    }

    /// Iterates over the catalog entries visible on this rail.
    pub fn command_specs(self) -> impl Iterator<Item = &'static CommandUiSpec> {
        self.ordered_command_specs().iter().copied()
    }

    pub(super) fn ordered_command_specs(self) -> &'static [&'static CommandUiSpec] {
        match self.side {
            RailSide::Left => &ORDERED_RAIL_SPECS[..RAIL_COMMAND_COUNTS[0]],
            RailSide::Right => &ORDERED_RAIL_SPECS[RAIL_COMMAND_COUNTS[0]..],
        }
    }

    pub(super) fn group_count(self) -> usize {
        let specs = self.ordered_command_specs();
        usize::from(!specs.is_empty())
            + specs
                .windows(2)
                .filter(|pair| pair[0].rail.map(|p| p.group) != pair[1].rail.map(|p| p.group))
                .count()
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
    rail_text: crate::i18n::commands::Text,
    menu_text: crate::i18n::commands::Text,
    tooltip_text: crate::i18n::commands::Text,
}

impl CommandUiSpec {
    #[must_use]
    pub fn localized_rail_label(self) -> &'static str {
        self.rail_text.get()
    }
    #[must_use]
    pub fn localized_menu_label(self) -> &'static str {
        self.menu_text.get()
    }
    #[must_use]
    pub fn localized_tooltip_label(self) -> &'static str {
        self.tooltip_text.get()
    }
    /// Returns the spoken one-line name exposed by a standard rail button's
    /// catalog-owned window text.
    #[must_use]
    pub fn rail_spoken_label(self) -> String {
        self.localized_rail_label().replace('\n', " ")
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
    ($id:ident, $rail:expr, $rail_label:ident, $menu:expr, $menu_label:ident,
     $tooltip:ident, $shortcut:expr, $enable:ident, $mutation:ident, $display:ident) => {
        CommandUiSpec {
            id: $id,
            rail: $rail,
            rail_label: crate::i18n::commands::Text::$rail_label
                .in_language(crate::i18n::Language::Korean),
            menu: $menu,
            menu_label: crate::i18n::commands::Text::$menu_label
                .in_language(crate::i18n::Language::Korean),
            tooltip_label: crate::i18n::commands::Text::$tooltip
                .in_language(crate::i18n::Language::Korean),
            rail_text: crate::i18n::commands::Text::$rail_label,
            menu_text: crate::i18n::commands::Text::$menu_label,
            tooltip_text: crate::i18n::commands::Text::$tooltip,
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
        ApplyRail,
        menu(MenuGroup::File, 1, 0),
        ApplyMenu,
        ApplyTooltip,
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
        ReplaceRail,
        menu(MenuGroup::Transform, 0, 0),
        ReplaceMenu,
        ReplaceTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PREFIX,
        rail(RailSide::Left, 1, 1),
        PrefixRail,
        menu(MenuGroup::Transform, 0, 1),
        PrefixMenu,
        PrefixTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SUFFIX,
        rail(RailSide::Left, 1, 2),
        SuffixRail,
        menu(MenuGroup::Transform, 0, 2),
        SuffixMenu,
        SuffixTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_NAME,
        rail(RailSide::Left, 2, 0),
        ClearNameRail,
        menu(MenuGroup::Transform, 1, 0),
        ClearNameMenu,
        ClearNameTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_POSITION,
        rail(RailSide::Left, 2, 1),
        DeletePositionRail,
        menu(MenuGroup::Transform, 1, 1),
        DeletePositionMenu,
        DeletePositionTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        DELETE_DELIMITED,
        rail(RailSide::Left, 2, 2),
        DeleteDelimitedRail,
        menu(MenuGroup::Transform, 1, 2),
        DeleteDelimitedMenu,
        DeleteDelimitedTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        KEEP_DIGITS,
        rail(RailSide::Left, 3, 0),
        KeepDigitsRail,
        menu(MenuGroup::Transform, 2, 0),
        KeepDigitsMenu,
        KeepDigitsTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PAD_DIGITS,
        rail(RailSide::Left, 3, 1),
        PadDigitsRail,
        menu(MenuGroup::Transform, 2, 1),
        PadDigitsMenu,
        PadDigitsTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        SEQUENCE,
        rail(RailSide::Left, 3, 2),
        SequenceRail,
        menu(MenuGroup::Transform, 2, 2),
        SequenceMenu,
        SequenceTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        RESET,
        rail(RailSide::Right, 0, 0),
        ResetRail,
        menu(MenuGroup::Edit, 2, 0),
        ResetMenu,
        ResetTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        CLEAR_LIST,
        None,
        ClearListRail,
        menu(MenuGroup::Edit, 3, 0),
        ClearListMenu,
        ClearListTooltip,
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
        ManualChangeRail,
        menu(MenuGroup::Edit, 0, 0),
        ManualChangeMenu,
        ManualChangeTooltip,
        legacy(LegacyVirtualKey::F2, LegacyShortcutModifiers::None, "F2"),
        Selection,
        Model,
        SingleRow
    ),
    command_ui_spec!(
        SORT,
        rail(RailSide::Right, 1, 2),
        SortRail,
        menu(MenuGroup::Edit, 1, 2),
        SortMenu,
        SortTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_PREFIX,
        rail(RailSide::Right, 3, 0),
        ParentPrefixRail,
        menu(MenuGroup::Transform, 4, 0),
        ParentPrefixMenu,
        ParentPrefixTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        PARENT_SUFFIX,
        rail(RailSide::Right, 3, 1),
        ParentSuffixRail,
        menu(MenuGroup::Transform, 4, 1),
        ParentSuffixMenu,
        ParentSuffixTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        UNIFY_PATH,
        None,
        UnifyPathRail,
        menu(MenuGroup::Edit, 2, 1),
        UnifyPathMenu,
        UnifyPathTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_DELETE,
        rail(RailSide::Right, 2, 0),
        ExtDeleteRail,
        menu(MenuGroup::Transform, 3, 0),
        ExtDeleteMenu,
        ExtDeleteTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_ADD,
        rail(RailSide::Right, 2, 1),
        ExtAddRail,
        menu(MenuGroup::Transform, 3, 1),
        ExtAddMenu,
        ExtAddTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        EXT_REPLACE,
        rail(RailSide::Right, 2, 2),
        ExtReplaceRail,
        menu(MenuGroup::Transform, 3, 2),
        ExtReplaceMenu,
        ExtReplaceTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        ADD_FILES,
        None,
        AddFilesRail,
        menu(MenuGroup::File, 0, 0),
        AddFilesMenu,
        AddFilesTooltip,
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
        CopyNamesRail,
        menu(MenuGroup::File, 2, 0),
        CopyNamesMenu,
        CopyNamesTooltip,
        None,
        Rows,
        None,
        NoRows
    ),
    command_ui_spec!(
        SAVE_NAMES,
        None,
        SaveNamesRail,
        menu(MenuGroup::File, 2, 1),
        SaveNamesMenu,
        SaveNamesTooltip,
        None,
        Rows,
        Filesystem,
        NoRows
    ),
    command_ui_spec!(
        COPY_PATHS,
        None,
        CopyPathsRail,
        menu(MenuGroup::File, 3, 0),
        CopyPathsMenu,
        CopyPathsTooltip,
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
        SavePathsRail,
        menu(MenuGroup::File, 3, 1),
        SavePathsMenu,
        SavePathsTooltip,
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
        ImportNamesRail,
        menu(MenuGroup::File, 4, 0),
        ImportNamesMenu,
        ImportNamesTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
    command_ui_spec!(
        IMPORT_PATHS,
        None,
        ImportPathsRail,
        menu(MenuGroup::File, 4, 1),
        ImportPathsMenu,
        ImportPathsTooltip,
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
        MoveUpRail,
        menu(MenuGroup::Edit, 1, 0),
        MoveUpMenu,
        MoveUpTooltip,
        legacy(LegacyVirtualKey::Up, LegacyShortcutModifiers::Alt, "Alt+↑"),
        Selection,
        Model,
        MovedRows
    ),
    command_ui_spec!(
        MOVE_DOWN,
        None,
        MoveDownRail,
        menu(MenuGroup::Edit, 1, 1),
        MoveDownMenu,
        MoveDownTooltip,
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
        ShowFullPathRail,
        menu(MenuGroup::View, 0, 0),
        ShowFullPathMenu,
        ShowFullPathTooltip,
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_SIZE,
        None,
        ShowSizeRail,
        menu(MenuGroup::View, 0, 1),
        ShowSizeMenu,
        ShowSizeTooltip,
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_MODIFIED,
        None,
        ShowModifiedRail,
        menu(MenuGroup::View, 0, 2),
        ShowModifiedMenu,
        ShowModifiedTooltip,
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        SHOW_CREATED,
        None,
        ShowCreatedRail,
        menu(MenuGroup::View, 0, 3),
        ShowCreatedMenu,
        ShowCreatedTooltip,
        None,
        Always,
        None,
        Columns
    ),
    command_ui_spec!(
        VERSION,
        None,
        VersionRail,
        menu(MenuGroup::Help, 0, 0),
        VersionMenu,
        VersionTooltip,
        None,
        Always,
        None,
        NoRows
    ),
    command_ui_spec!(
        RESET_PATH,
        None,
        ResetPathRail,
        menu(MenuGroup::Edit, 2, 2),
        ResetPathMenu,
        ResetPathTooltip,
        None,
        Rows,
        Model,
        AllRows
    ),
];

pub const DELETE_SELECTED_UI_SPEC: CommandUiSpec = command_ui_spec!(
    DELETE_SELECTED_COMMAND,
    rail(RailSide::Right, 1, 1),
    DeleteSelectedCommandRail,
    menu(MenuGroup::Edit, 0, 1),
    DeleteSelectedCommandMenu,
    DeleteSelectedCommandTooltip,
    legacy(
        LegacyVirtualKey::Delete,
        LegacyShortcutModifiers::None,
        "Delete"
    ),
    Selection,
    Model,
    AllRows
);

const fn rail_command_counts() -> [usize; 2] {
    let mut counts = [0; 2];
    let mut index = 0;
    while index <= COMMAND_UI_SPECS.len() {
        let spec = if index < COMMAND_UI_SPECS.len() {
            &COMMAND_UI_SPECS[index]
        } else {
            &DELETE_SELECTED_UI_SPEC
        };
        if let Some(placement) = spec.rail {
            let side = match placement.side {
                RailSide::Left => 0,
                RailSide::Right => 1,
            };
            counts[side] += 1;
        }
        index += 1;
    }
    counts
}

const RAIL_COMMAND_COUNTS: [usize; 2] = rail_command_counts();
const RAIL_COMMAND_COUNT: usize = RAIL_COMMAND_COUNTS[0] + RAIL_COMMAND_COUNTS[1];

const fn rail_order_key(spec: &CommandUiSpec) -> u32 {
    match spec.rail {
        Some(placement) => {
            let side = match placement.side {
                RailSide::Left => 0,
                RailSide::Right => 1,
            };
            (side << 16) | ((placement.group as u32) << 8) | placement.order as u32
        }
        None => u32::MAX,
    }
}

const fn ordered_rail_specs() -> [&'static CommandUiSpec; RAIL_COMMAND_COUNT] {
    let mut specs = [&DELETE_SELECTED_UI_SPEC; RAIL_COMMAND_COUNT];
    let mut catalog_index = 0;
    let mut active_count = 0;
    while catalog_index <= COMMAND_UI_SPECS.len() {
        let spec = if catalog_index < COMMAND_UI_SPECS.len() {
            &COMMAND_UI_SPECS[catalog_index]
        } else {
            &DELETE_SELECTED_UI_SPEC
        };
        if spec.rail.is_some() {
            specs[active_count] = spec;
            active_count += 1;
        }
        catalog_index += 1;
    }
    // Compile-time stable insertion sort: equal keys retain catalog enumeration
    // order, including Delete Selected's position after the ID-indexed catalog.
    let mut index = 1;
    while index < specs.len() {
        let spec = specs[index];
        let mut position = index;
        while position > 0 && rail_order_key(specs[position - 1]) > rail_order_key(spec) {
            specs[position] = specs[position - 1];
            position -= 1;
        }
        specs[position] = spec;
        index += 1;
    }
    specs
}

// Only visible references are retained; no runtime collection or sorting, and
// no duplicate command metadata. ID lookup keeps the original catalog order.
static ORDERED_RAIL_SPECS: [&CommandUiSpec; RAIL_COMMAND_COUNT] = ordered_rail_specs();

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
        || spec.localized_menu_label().to_owned(),
        |shortcut| format!("{}\t{}", spec.localized_menu_label(), shortcut.display),
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
            label: spec.localized_rail_label(),
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
