"""Strict predicates for the fixed native-menu-only layout observation."""

from __future__ import annotations

import hashlib

from vm_automated_evidence import EvidenceError, require_exact_keys, require_int
from vm_automated_platform import contains, rectangle
from vm_automated_state import Identity, clean_journal_inventory, leaf_name


RAIL_IDS = {
    "32771", "32772", "32773", "32774", "32775", "32776", "32777", "32778", "32779",
    "32780", "32781", "32783", "65535", "32784", "32788", "32789", "32790", "32785", "32786",
}

# Positions are zero-based GetMenuItemInfoW positions in the complete native
# menu tree.  They are source-owned and are deliberately independent of UIA.
COMMAND_PATHS = {
    32771: (0, 2),
    32781: (1, 7),
    32783: (1, 0),
    65535: (1, 1),
    32784: (1, 5),
    32772: (3, 0, 0),
    32773: (3, 0, 1),
    32774: (3, 0, 2),
    32775: (3, 1, 0),
    32776: (3, 1, 1),
    32777: (3, 1, 2),
    32778: (3, 2, 0),
    32779: (3, 2, 1),
    32780: (3, 2, 2),
    32788: (3, 3, 0),
    32789: (3, 3, 1),
    32790: (3, 3, 2),
    32785: (3, 4, 0),
    32786: (3, 4, 1),
}
ENABLED_COMMANDS = frozenset(COMMAND_PATHS) - {32771, 32781, 32783, 65535}
DISABLED_COMMANDS = frozenset(COMMAND_PATHS) - ENABLED_COMMANDS

_PARENT_PREFIX = "한글-매우-긴-상위-경로-공통-자료-보관-2026-09-"
_LEAF_PREFIX = "한글-😀-아주긴공통접두어-월별정리-원본자료-검토완료-배포대기-장기보존-최종승인-추가검증-"
_FIXTURE_DIRECTORIES = (_PARENT_PREFIX + "A-😀", _PARENT_PREFIX + "B-😀")
_FIXTURE_FILES = {
    _FIXTURE_DIRECTORIES[0] + "/" + _LEAF_PREFIX + "0001-final.txt": b"long-name-ux-fixture-0\n",
    _FIXTURE_DIRECTORIES[0] + "/" + _LEAF_PREFIX + "0002-final.md": b"long-name-ux-fixture-1\n",
    _FIXTURE_DIRECTORIES[1] + "/" + _LEAF_PREFIX + "0001-final.txt": b"long-name-ux-fixture-2\n",
}
_MAX_MENU_FIXTURE_ENTRIES = 16
_MAX_MENU_FIXTURE_DEPTH = 3
_MAX_MENU_FIXTURE_BYTES = 64 * 1024 * 1024
_MAX_MENU_FIXTURE_AGGREGATE_BYTES = 512 * 1024 * 1024

_VK = {
    "alt-f": [18, 70], "alt-e": [18, 69], "alt-t": [18, 84],
    "down": [40], "right": [39], "left": [37], "escape": [27],
}
_BINDING_KEYS = {"automation_id", "control_type", "visible", "enabled", "keyboard_focusable",
                 "bounds", "pid", "session_id", "root_hwnd"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def _path(value: object, label: str) -> tuple[int, ...]:
    require(type(value) is list and 1 <= len(value) <= 3, f"{label} is not a bounded menu path.")
    result = tuple(require_int(item, 0, 31, f"{label} position") for item in value)
    return result


def _binding(value: object, display: dict, work: dict, *, list_focus: bool) -> dict:
    item = require_exact_keys(value, _BINDING_KEYS, "Menu focus binding")
    for key, expected in (("pid", display["process_id"]), ("session_id", display["session_id"]),
                          ("root_hwnd", display["hwnd"])):
        require_int(item[key], expected, expected, "Menu focus ownership")
    for field in ("visible", "enabled", "keyboard_focusable"):
        require(type(item[field]) is bool, "Menu focus availability is unobserved.")
    bounds = rectangle(item["bounds"])
    if list_focus:
        require(item["automation_id"] == "1000" and item["control_type"] == "ControlType.DataGrid" and
                item["visible"] and item["enabled"] and item["keyboard_focusable"] and contains(work, bounds),
                "Native-menu traversal did not begin or end on the visible file list.")
    return item


def _foreground(value: object, display: dict) -> dict:
    row = require_exact_keys(value, {"hwnd", "process_id", "session_id", "window_class"}, "Menu foreground")
    require_int(row["hwnd"], display["hwnd"], display["hwnd"], "Menu foreground HWND")
    require_int(row["process_id"], display["process_id"], display["process_id"], "Menu foreground PID")
    require_int(row["session_id"], display["session_id"], display["session_id"], "Menu foreground session")
    require(row["window_class"] == "DarkReNamerWindow", "Menu foreground is not the candidate workbench.")
    return row


def _controls(value: object, display: dict, work: dict) -> dict[str, dict]:
    require(type(value) is list and len(value) == 2,
            "Menu-only layout must inventory the visible workbench and file list.")
    seen: dict[str, dict] = {}
    for raw in value:
        item = require_exact_keys(raw, _BINDING_KEYS, "Menu-only control")
        identifier = item["automation_id"]
        require(type(identifier) is str and identifier not in seen, "Menu-only control inventory is duplicated.")
        for key, expected in (("pid", display["process_id"]), ("session_id", display["session_id"]),
                              ("root_hwnd", display["hwnd"])):
            require_int(item[key], expected, expected, "Menu-only control ownership")
        for field in ("visible", "enabled", "keyboard_focusable"):
            require(type(item[field]) is bool, "Menu-only control state is unobserved.")
        expected_type = ("ControlType.Window" if identifier == "" else
                         "ControlType.DataGrid" if identifier == "1000" else "ControlType.Button")
        require(item["control_type"] == expected_type, "Menu-only control type differs from the workbench contract.")
        bounds = rectangle(item["bounds"])
        require(identifier in {"", "1000"} and item["visible"] and contains(work, bounds),
                "Required menu-only base control is missing or clipped.")
        seen[identifier] = item
    require(set(seen) == {"", "1000"}, "Menu-only visible control inventory differs from the source contract.")
    return seen


def _hidden_controls(value: object, display: dict) -> None:
    require(type(value) is list and len(value) == len(COMMAND_PATHS),
            "Native hidden rail inventory must contain all nineteen commands.")
    seen_commands, seen_hwnds = set(), set()
    for raw in value:
        row = require_exact_keys(raw, {"command_id", "hwnd", "control_id", "window_class", "visible", "enabled",
                                       "pid", "session_id", "parent_hwnd", "root_hwnd", "rect"},
                                 "Native hidden rail")
        command = require_int(row["command_id"], 1, 0xFFFF, "Hidden rail command")
        hwnd = require_int(row["hwnd"], 1, (1 << 63) - 1, "Hidden rail HWND")
        require_int(row["control_id"], command, command, "Hidden rail control ID")
        require_int(row["pid"], display["process_id"], display["process_id"], "Hidden rail PID")
        require_int(row["session_id"], display["session_id"], display["session_id"], "Hidden rail session")
        require_int(row["parent_hwnd"], display["hwnd"], display["hwnd"], "Hidden rail parent")
        require_int(row["root_hwnd"], display["hwnd"], display["hwnd"], "Hidden rail root")
        rect = require_exact_keys(row["rect"], {"left", "top", "right", "bottom"}, "Hidden rail rectangle")
        for coordinate in rect.values():
            require_int(coordinate, -65_536, 65_536, "Hidden rail coordinate")
        require(rect["right"] >= rect["left"] and rect["bottom"] >= rect["top"],
                "Hidden rail rectangle is inverted.")
        require(command in COMMAND_PATHS and command not in seen_commands and hwnd not in seen_hwnds and
                row["window_class"] == "Button" and row["visible"] is False and
                type(row["enabled"]) is bool and row["enabled"] is (command in ENABLED_COMMANDS),
                "Hidden rail identity or state differs from the fixed menu-only contract.")
        seen_commands.add(command)
        seen_hwnds.add(hwnd)
    require(seen_commands == set(COMMAND_PATHS), "Native hidden rail command inventory is incomplete.")


def _tree(value: object) -> dict[tuple[int, ...], dict]:
    require(type(value) is list and 1 <= len(value) <= 128, "Native menu tree is missing or unbounded.")
    tree: dict[tuple[int, ...], dict] = {}
    commands: set[int] = set()
    for raw in value:
        row = require_exact_keys(raw, {"menu_path", "position", "item_type", "command_id", "state_flags",
                                       "enabled", "checked"},
                                 "Native menu item")
        parent_raw = row["menu_path"]
        require(type(parent_raw) is list and len(parent_raw) <= 2, "Native menu ancestor path is unbounded.")
        parent = (() if not parent_raw else _path(parent_raw, "Native menu ancestor"))
        position = require_int(row["position"], 0, 31, "Native menu position")
        path = parent + (position,)
        require(path not in tree, "Native menu path is duplicated.")
        require(type(row["item_type"]) is str and row["item_type"] in {"command", "submenu", "separator"} and
                type(row["enabled"]) is bool and type(row["checked"]) is bool,
                "Native menu item metadata is malformed.")
        flags = require_int(row["state_flags"], 0, 0xFF, "Native menu state flags")
        require(flags & 0x80 == 0 and row["enabled"] is ((flags & 3) == 0) and
                row["checked"] is bool(flags & 8),
                "Native menu enabled or checked state does not derive from raw flags.")
        if row["item_type"] == "command":
            command = require_int(row["command_id"], 1, 0xFFFF, "Native menu command")
            require(command not in commands, "Native menu command is duplicated.")
            commands.add(command)
        else:
            require(row["command_id"] is None, "Submenu or separator carries a command identifier.")
            if row["item_type"] == "submenu":
                require(row["enabled"] is True and row["checked"] is False,
                        "Required native submenu is disabled or checked.")
        tree[path] = row
    require({path for path in tree if len(path) == 1} == {(index,) for index in range(6)} and
            all(tree[(index,)]["item_type"] == "submenu" for index in range(6)),
            "Native menu bar differs from the fixed six-popup structure.")
    for path, row in tree.items():
        if len(path) > 1:
            require(path[:-1] in tree and tree[path[:-1]]["item_type"] == "submenu",
                    "Native menu item has no owning submenu.")
        children = sorted(child[-1] for child in tree if len(child) == len(path) + 1 and child[:-1] == path)
        require((row["item_type"] == "submenu") == bool(children),
                "Native submenu completeness differs from its descendants.")
        require(not children or children == list(range(len(children))),
                "Native submenu positions are incomplete or non-contiguous.")
    for command, path in COMMAND_PATHS.items():
        require(path in tree and tree[path]["item_type"] == "command" and
                tree[path]["command_id"] == command and tree[path]["checked"] is False and
                tree[path]["enabled"] is (command in ENABLED_COMMANDS),
                "Native command path or enabled state differs from the fixed fixture.")
    return tree


def _relative_path(value: object) -> str:
    require(type(value) is str and 0 < len(value) <= 767 and "\\" not in value,
            "Menu fixture relative path is missing, unbounded, or non-canonical.")
    segments = value.split("/")
    require(1 <= len(segments) <= _MAX_MENU_FIXTURE_DEPTH and
            all(segment and leaf_name(segment) == segment for segment in segments),
            "Menu fixture relative path is unsafe or exceeds its depth bound.")
    return "/".join(segments)


def _fixture_entries(value: object, root_identity: Identity) -> dict[str, tuple[str, int, object, Identity]]:
    require(type(value) is list and 0 < len(value) <= _MAX_MENU_FIXTURE_ENTRIES,
            "Menu fixture inventory is missing or exceeds its entry bound.")
    entries: dict[str, tuple[str, int, object, Identity]] = {}
    folded: set[str] = set()
    identities = {root_identity}
    ordered_paths: list[str] = []
    aggregate_bytes = 0
    for raw in value:
        row = require_exact_keys(raw, {"relative_path", "kind", "bytes", "content_sha256",
                                       "file_identity"}, "Menu fixture row")
        path = _relative_path(row["relative_path"])
        require(path.casefold() not in folded, "Menu fixture inventory repeats or aliases a path.")
        require(type(row["kind"]) is str and row["kind"] in {"directory", "file"},
                "Menu fixture row is not an ordinary file or directory.")
        size = require_int(row["bytes"], 0, _MAX_MENU_FIXTURE_BYTES, "Menu fixture bytes")
        aggregate_bytes += size
        require(aggregate_bytes <= _MAX_MENU_FIXTURE_AGGREGATE_BYTES,
                "Menu fixture inventory exceeds its aggregate byte bound.")
        identity = Identity.parse(row["file_identity"])
        require(identity.volume == root_identity.volume and identity not in identities,
                "Menu fixture identity is foreign, duplicated, or aliases the root.")
        if row["kind"] == "directory":
            require(size == 0 and row["content_sha256"] is None,
                    "Menu fixture directory carries file content metadata.")
        else:
            require(type(row["content_sha256"]) is str,
                    "Menu fixture file digest is missing.")
        identities.add(identity)
        folded.add(path.casefold())
        ordered_paths.append(path)
        entries[path] = (row["kind"], size, row["content_sha256"], identity)

    require(ordered_paths == sorted(ordered_paths),
            "Menu fixture inventory is not in canonical relative-path order.")
    expected_paths = set(_FIXTURE_DIRECTORIES) | set(_FIXTURE_FILES)
    require(set(entries) == expected_paths, "Menu fixture inventory differs from the fixed standard fixture.")
    for directory in _FIXTURE_DIRECTORIES:
        require(entries[directory][0:3] == ("directory", 0, None),
                "Menu fixture directory metadata differs from the fixed standard fixture.")
    for path, body in _FIXTURE_FILES.items():
        expected = ("file", len(body), hashlib.sha256(body).hexdigest())
        require(entries[path][0:3] == expected,
                "Menu fixture file content differs from the fixed standard fixture.")
        require(path.rsplit("/", 1)[0] in entries,
                "Menu fixture file has no observed parent directory.")
    return entries


def _state(value: object, environment: dict) -> dict:
    row = require_exact_keys(value, {"fixture_root", "root_identity", "fixture_entries", "journal_entries"},
                             "Menu navigation state")
    volume = environment["fixture_volume"]
    require(row["fixture_root"] == volume["root_path"] and
            Identity.parse(row["root_identity"]) == Identity.parse(volume["root_identity"]),
            "Menu navigation state belongs to another fixture root.")
    root_identity = Identity.parse(row["root_identity"])
    _fixture_entries(row["fixture_entries"], root_identity)
    clean_journal_inventory(row["journal_entries"])
    return row


def verify_native_menu_layout(layout: object, environment: dict) -> None:
    """Verify the text-150 small-cell menu fallback without producer verdicts."""
    outer = require_exact_keys(layout, {"controls", "focus", "screenshots", "native_menu_only"},
                               "Native-menu layout observations")
    display = environment["target_display"]
    work = rectangle(display["work_rect"])
    window = rectangle(display["window_rect"])
    controls = _controls(outer["controls"], display, work)
    require(type(outer["focus"]) is list and len(outer["focus"]) == 1,
            "Native-menu layout requires one final list focus observation.")
    require(_binding(outer["focus"][0], display, work, list_focus=True) == controls["1000"],
            "Final menu-only list focus differs from the visible control inventory.")

    row = require_exact_keys(outer["native_menu_only"],
                             {"schema_version", "variant", "hidden_rail_controls", "menu_tree", "initial", "events", "final",
                              "state_before", "state_after"}, "Native-menu traversal")
    require_int(row["schema_version"], 1, 1, "Native-menu schema")
    require(row["variant"] == "native-menu-only", "Native-menu discriminator differs from the fixed profile.")
    _hidden_controls(row["hidden_rail_controls"], display)
    tree = _tree(row["menu_tree"])
    before, after = _state(row["state_before"], environment), _state(row["state_after"], environment)
    require(before == after, "Native-menu keyboard traversal changed fixture or journal state.")

    observation_keys = {"foreground", "focused", "open_menu_paths", "popups"}

    def observation(value: object, *, endpoint: bool, event: bool = False) -> tuple[list[tuple[int, ...]], object]:
        keys = observation_keys if not event else {"foreground", "open_menu_paths", "highlighted", "popups"}
        state = require_exact_keys(value, keys, "Native-menu observation")
        _foreground(state["foreground"], display)
        if not event:
            require(_binding(state["focused"], display, work, list_focus=endpoint) == controls["1000"],
                    "Menu endpoint focus differs from the visible file list.")
        require(type(state["open_menu_paths"]) is list and len(state["open_menu_paths"]) <= 2,
                "Native-menu popup depth is unavailable or exceeds two.")
        open_paths = [_path(item, "Open menu") for item in state["open_menu_paths"]]
        require(len(set(open_paths)) == len(open_paths) and
                all(path in tree and tree[path]["item_type"] == "submenu" for path in open_paths) and
                all(open_paths[index][:-1] == open_paths[index - 1] for index in range(1, len(open_paths))),
                "Open popup paths do not form one bounded native menu chain.")
        popups = state["popups"]
        require(type(popups) is list and len(popups) == len(open_paths), "Popup windows differ from the open menu chain.")
        popup_by_path = {}
        popup_paths = []
        handles = set()
        for raw_popup in popups:
            popup = require_exact_keys(raw_popup, {"menu_path", "hwnd", "pid", "session_id", "window_class", "rect"},
                                       "Native popup")
            path = _path(popup["menu_path"], "Native popup")
            require(path in open_paths and path not in popup_by_path, "Native popup path is absent or duplicated.")
            hwnd = require_int(popup["hwnd"], 1, (1 << 63) - 1, "Native popup HWND")
            require(hwnd != display["hwnd"] and hwnd not in handles, "Native popup HWND is reused or is the workbench.")
            require_int(popup["pid"], display["process_id"], display["process_id"], "Native popup PID")
            require_int(popup["session_id"], display["session_id"], display["session_id"], "Native popup session")
            bounds = rectangle(popup["rect"])
            require(popup["window_class"] == "#32768" and contains(work, bounds),
                    "Native popup is foreign or outside the observed work area.")
            handles.add(hwnd)
            popup_by_path[path] = bounds
            popup_paths.append(path)
        require(popup_paths == open_paths, "Native popup rows are not ordered by their menu depth.")
        if not event:
            return open_paths, None
        highlighted = state["highlighted"]
        if highlighted is None:
            return open_paths, None
        item = require_exact_keys(highlighted, {"menu_path", "position", "command_id", "item_rect", "state_flags"},
                                  "Highlighted menu item")
        parent_raw = item["menu_path"]
        require(type(parent_raw) is list and len(parent_raw) <= 2,
                "Highlighted menu ancestor path is malformed.")
        parent = () if not parent_raw else _path(parent_raw, "Highlighted menu ancestor")
        path = parent + (require_int(item["position"], 0, 31, "Highlighted menu position"),)
        flags = require_int(item["state_flags"], 0, 0xFF, "Highlighted menu flags")
        require(path in tree and item["command_id"] == tree[path]["command_id"] and flags & 0x80 and
                flags & ~0x80 == tree[path]["state_flags"],
                "Highlighted menu item differs from its immutable native tree row.")
        item_rect = rectangle(item["item_rect"])
        if not parent:
            require(not open_paths and not popups and len(path) == 1 and
                    tree[path]["item_type"] == "submenu" and item["command_id"] is None and
                    contains(window, item_rect),
                    "Closed popup observation is not the exact candidate menu-bar highlight.")
        else:
            require(bool(open_paths) and path[:-1] == open_paths[-1] and path[:-1] in popup_by_path and
                    tree[path]["item_type"] != "separator" and
                    contains(popup_by_path[path[:-1]], item_rect),
                    "Highlighted menu item is not bound to its actual candidate popup.")
        return open_paths, path

    initial_paths, _ = observation(row["initial"], endpoint=True)
    require(not initial_paths and row["initial"]["popups"] == [], "Native-menu traversal began with an open popup.")
    events = row["events"]
    require(type(events) is list and 1 <= len(events) <= 128, "Native-menu transcript is missing or unbounded.")
    open_paths: list[tuple[int, ...]] = []
    highlighted: tuple[int, ...] | None = None
    roots_seen: set[tuple[int, ...]] = set()
    reached: set[int] = set()

    def navigable(parent: tuple[int, ...]) -> list[tuple[int, ...]]:
        # Native menus highlight disabled commands while navigating; only
        # separators are skipped. Highlighting does not activate a command.
        return [path for path, item in sorted(tree.items())
                if path[:-1] == parent and item["item_type"] != "separator"]

    for sequence, raw_event in enumerate(events, 1):
        event = require_exact_keys(raw_event, {"sequence", "input", "virtual_keys", "foreground",
                                               "open_menu_paths", "highlighted", "popups"}, "Native-menu event")
        require_int(event["sequence"], sequence, sequence, "Native-menu event sequence")
        action = event["input"]
        require(type(action) is str and action in _VK and event["virtual_keys"] == _VK[action],
                "Native-menu input is outside the frozen keyboard contract.")
        opener = action.startswith("alt-")
        if opener:
            require(not open_paths and highlighted is None, "Menu mnemonic was sent while another popup was open.")
            root = ({"alt-f": (0,), "alt-e": (1,), "alt-t": (3,)})[action]
            open_paths, highlighted = [root], None
            roots_seen.add(root)
        elif action == "down":
            require(bool(open_paths), "Down was sent without an open candidate menu.")
            choices = navigable(open_paths[-1])
            require(bool(choices), "Down targeted a menu with no navigable item.")
            highlighted = choices[0] if highlighted is None else choices[(choices.index(highlighted) + 1) % len(choices)]
        elif action == "right":
            require(highlighted is not None and tree[highlighted]["item_type"] == "submenu" and
                    tree[highlighted]["enabled"] and len(open_paths) < 2,
                    "Right did not enter the currently highlighted bounded submenu.")
            open_paths.append(highlighted)
            choices = navigable(highlighted)
            require(bool(choices), "Opened submenu has no navigable item.")
            highlighted = choices[0]
        elif action == "left":
            require(len(open_paths) == 2, "Left did not close a nested candidate submenu.")
            highlighted = open_paths.pop()
        else:
            if len(open_paths) == 2:
                highlighted = open_paths.pop()
            elif len(open_paths) == 1:
                highlighted = open_paths.pop()
            else:
                require(highlighted is not None and len(highlighted) == 1 and
                        tree[highlighted]["item_type"] == "submenu",
                        "Escape was sent without an active candidate menu bar.")
                highlighted = None
        observed_paths, observed_highlight = observation(
            {key: event[key] for key in {"foreground", "open_menu_paths", "highlighted", "popups"}},
            endpoint=False, event=True)
        if opener:
            choices = navigable(open_paths[-1])
            require(bool(choices), "Menu mnemonic opened a menu with no keyboard-navigable row.")
            require(observed_paths == open_paths and observed_highlight in {None, choices[0]},
                    "Menu mnemonic highlighted an item other than the first keyboard-navigable row.")
            highlighted = observed_highlight
        else:
            require(observed_paths == open_paths and observed_highlight == highlighted,
                    "Native-menu observations do not replay the frozen keyboard state machine.")
        if highlighted is not None and tree[highlighted]["item_type"] == "command" and tree[highlighted]["enabled"]:
            reached.add(tree[highlighted]["command_id"])
    final_paths, _ = observation(row["final"], endpoint=True)
    require(not final_paths and row["final"]["popups"] == [] and open_paths == [] and highlighted is None,
            "Native-menu traversal did not close every candidate popup.")
    require(roots_seen == {(0,), (1,), (3,)} and reached & set(COMMAND_PATHS) == set(ENABLED_COMMANDS) and
            not (reached & set(DISABLED_COMMANDS)),
            "Native-menu keyboard traversal did not reach every enabled required command exactly through its menu tree.")
