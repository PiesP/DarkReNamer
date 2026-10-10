"""Synthetic native-menu observations shared by independent tooling suites."""

from copy import deepcopy
import hashlib

PID, SESSION, MAIN = 1234, 2, 5678
RECT = {"left": 0, "top": 0, "right": 800, "bottom": 560}
IDENTITY = {"volume_serial": "1" * 16, "file_id": "2" * 32}

# Frozen producer observations. Keep these independent of verifier inventory.
HIDDEN_COMMAND_IDS = (
    32771, 32781, 32783, 65535, 32784,
    32772, 32773, 32774, 32775, 32776, 32777, 32778, 32779, 32780,
    32788, 32789, 32790, 32785, 32786,
)
ENABLED_HIDDEN_COMMAND_IDS = frozenset({
    32784, 32772, 32773, 32774, 32775, 32776, 32777, 32778, 32779,
    32780, 32788, 32789, 32790, 32785, 32786,
})
PARENT_PREFIX = "한글-매우-긴-상위-경로-공통-자료-보관-2026-09-"
LEAF_PREFIX = "한글-😀-아주긴공통접두어-월별정리-원본자료-검토완료-배포대기-장기보존-최종승인-추가검증-"
FIXTURE_DIRECTORIES = (PARENT_PREFIX + "A-😀", PARENT_PREFIX + "B-😀")
FIXTURE_FILES = {
    FIXTURE_DIRECTORIES[0] + "/" + LEAF_PREFIX + "0001-final.txt": b"long-name-ux-fixture-0\n",
    FIXTURE_DIRECTORIES[0] + "/" + LEAF_PREFIX + "0002-final.md": b"long-name-ux-fixture-1\n",
    FIXTURE_DIRECTORIES[1] + "/" + LEAF_PREFIX + "0001-final.txt": b"long-name-ux-fixture-2\n",
}


def binding(identifier: str, control_type: str) -> dict:
    return {"automation_id": identifier, "control_type": control_type, "visible": True,
            "enabled": True, "keyboard_focusable": True,
            "bounds": {"left": 10, "top": 10, "right": 100, "bottom": 40},
            "pid": PID, "session_id": SESSION, "root_hwnd": MAIN}


def environment() -> dict:
    return {"fixture_volume": {"filesystem": "NTFS", "root_path": r"C:\fixture",
                               "root_identity": deepcopy(IDENTITY)},
            "target_display": {"hwnd": MAIN, "process_id": PID, "session_id": SESSION,
                               "work_rect": deepcopy(RECT), "window_rect": deepcopy(RECT)}}


def fixture_state() -> dict:
    rows = []
    for path in FIXTURE_DIRECTORIES:
        rows.append((path, "directory", 0, None))
    for path, body in FIXTURE_FILES.items():
        rows.append((path, "file", len(body), hashlib.sha256(body).hexdigest()))

    entries = []
    next_id = 3
    for path, kind, size, content in sorted(rows):
        entries.append({"relative_path": path, "kind": kind, "bytes": size,
                        "content_sha256": content,
                        "file_identity": {"volume_serial": "1" * 16,
                                          "file_id": f"{next_id:032x}"}})
        next_id += 1
    return {"fixture_root": r"C:\fixture", "root_identity": deepcopy(IDENTITY),
            "fixture_entries": entries,
            "journal_entries": []}


def tree_item(parent: tuple[int, ...], position: int, kind: str, command: int | None,
              *, enabled: bool = True) -> dict:
    flags = (0x10 if kind == "submenu" else 0) | (0 if enabled else 3 if kind == "separator" else 1)
    return {"menu_path": list(parent), "position": position, "item_type": kind,
            "command_id": command, "state_flags": flags, "enabled": enabled, "checked": False}


def menu_tree() -> list[dict]:
    rows = [tree_item((), position, "submenu", None) for position in range(6)]
    rows.extend([
        tree_item((0,), 0, "command", 32791), tree_item((0,), 1, "separator", None, enabled=False),
        tree_item((0,), 2, "command", 32771, enabled=False),
        tree_item((0,), 3, "separator", None, enabled=False), tree_item((0,), 4, "command", 32796),
        tree_item((0,), 5, "command", 32797), tree_item((0,), 6, "submenu", None),
        tree_item((0,), 7, "separator", None, enabled=False), tree_item((0,), 8, "command", 2),
        tree_item((0, 6), 0, "command", 32801),
        tree_item((1,), 0, "command", 32783, enabled=False),
        tree_item((1,), 1, "command", 65535, enabled=False),
        tree_item((1,), 2, "separator", None, enabled=False),
        tree_item((1,), 3, "command", 32798, enabled=False),
        tree_item((1,), 4, "command", 32799, enabled=False),
        tree_item((1,), 5, "command", 32784),
        tree_item((1,), 6, "separator", None, enabled=False),
        tree_item((1,), 7, "command", 32781, enabled=False),
        tree_item((1,), 8, "submenu", None),
        tree_item((1,), 9, "separator", None, enabled=False),
        tree_item((1,), 10, "command", 32782),
        tree_item((1, 8), 0, "command", 32802), tree_item((1, 8), 1, "command", 32803),
        tree_item((2,), 0, "command", 32804),
        tree_item((4,), 0, "command", 32805), tree_item((5,), 0, "command", 32806),
    ])
    groups = ((32772, 32773, 32774), (32775, 32776, 32777), (32778, 32779, 32780),
              (32788, 32789, 32790), (32785, 32786))
    for group, commands in enumerate(groups):
        rows.append(tree_item((3,), group, "submenu", None))
        rows.extend(tree_item((3, group), position, "command", command)
                    for position, command in enumerate(commands))
    return rows


def layout(*, opener_highlights: bool = False) -> dict:
    tree = menu_tree()
    by_path = {tuple(row["menu_path"]) + (row["position"],): row for row in tree}
    foreground = {"hwnd": MAIN, "process_id": PID, "session_id": SESSION,
                  "window_class": "DarkReNamerWindow"}
    list_binding = binding("1000", "ControlType.DataGrid")
    controls = [binding("", "ControlType.Window"), deepcopy(list_binding)]
    hidden = []
    for index, command in enumerate(HIDDEN_COMMAND_IDS):
        hidden.append({"command_id": command, "hwnd": 10_000 + index, "control_id": command,
                       "window_class": "Button", "visible": False,
                       "enabled": command in ENABLED_HIDDEN_COMMAND_IDS,
                       "pid": PID, "session_id": SESSION,
                       "parent_hwnd": MAIN, "root_hwnd": MAIN,
                       "rect": {"left": -500, "top": 10 + index, "right": -400, "bottom": 20 + index}})

    def event_observation(open_paths: list[tuple[int, ...]], highlighted: tuple[int, ...] | None) -> dict:
        popups = []
        for depth, path in enumerate(open_paths):
            popups.append({"menu_path": list(path), "hwnd": 20_000 + depth, "pid": PID,
                           "session_id": SESSION, "window_class": "#32768",
                           "rect": {"left": 100 + 200 * depth, "top": 100,
                                    "right": 290 + 200 * depth, "bottom": 500}})
        highlight = None
        if highlighted is not None:
            item = by_path[highlighted]
            if len(highlighted) == 1:
                item_rect = {"left": 0, "top": 0, "right": 1, "bottom": 1}
            else:
                depth = len(highlighted) - 2
                item_rect = {"left": 110 + 200 * depth, "top": 110,
                             "right": 200 + 200 * depth, "bottom": 130}
            highlight = {"menu_path": list(highlighted[:-1]), "position": highlighted[-1],
                         "command_id": item["command_id"], "state_flags": item["state_flags"] | 0x80,
                         "item_rect": item_rect}
        return {"foreground": deepcopy(foreground), "open_menu_paths": [list(path) for path in open_paths],
                "highlighted": highlight, "popups": popups}

    events = []
    state_open: list[tuple[int, ...]] = []
    current = None

    def emit(action: str, open_paths: list[tuple[int, ...]], highlighted: tuple[int, ...] | None) -> None:
        nonlocal state_open, current
        virtual = {"alt-f": [18, 70], "alt-e": [18, 69], "alt-t": [18, 84],
                   "down": [40], "right": [39], "left": [37], "escape": [27]}[action]
        events.append({"sequence": len(events) + 1, "input": action, "virtual_keys": virtual,
                       **event_observation(open_paths, highlighted)})
        state_open, current = list(open_paths), highlighted

    emit("alt-f", [(0,)], (0, 0) if opener_highlights else None)
    emit("escape", [], (0,))
    emit("escape", [], None)
    emit("alt-e", [(1,)], (1, 0) if opener_highlights else None)
    if not opener_highlights:
        emit("down", [(1,)], (1, 0))
    for position in (1, 3, 4, 5):
        emit("down", [(1,)], (1, position))
    emit("escape", [], (1,))
    emit("escape", [], None)
    groups = ((32772, 32773, 32774), (32775, 32776, 32777), (32778, 32779, 32780),
              (32788, 32789, 32790), (32785, 32786))
    for group, commands in enumerate(groups):
        emit("alt-t", [(3,)], (3, 0) if opener_highlights else None)
        for position in range(1 if opener_highlights else 0, group + 1):
            emit("down", [(3,)], (3, position))
        emit("right", [(3,), (3, group)], (3, group, 0))
        for position in range(1, len(commands)):
            emit("down", [(3,), (3, group)], (3, group, position))
        emit("left", [(3,)], (3, group))
        emit("escape", [], (3,))
        emit("escape", [], None)

    endpoint = {"foreground": deepcopy(foreground), "focused": deepcopy(list_binding),
                "open_menu_paths": [], "popups": []}
    state = fixture_state()
    return {"controls": controls, "focus": [deepcopy(list_binding)], "screenshots": [],
            "native_menu_only": {"schema_version": 1, "variant": "native-menu-only",
                                 "hidden_rail_controls": hidden, "menu_tree": tree,
                                 "initial": deepcopy(endpoint), "events": events, "final": deepcopy(endpoint),
                                 "state_before": deepcopy(state), "state_after": deepcopy(state)}}


def layout_for_environment(raw_environment: dict) -> dict:
    """Adapt the semantic fixture to a campaign cell without mocking its verifier."""
    display = raw_environment["target_display"]
    replacements = {PID: display["process_id"], MAIN: display["hwnd"]}

    def replace(value: object) -> object:
        if type(value) is dict:
            return {key: replace(item) for key, item in value.items()}
        if type(value) is list:
            return [replace(item) for item in value]
        return replacements.get(value, value) if type(value) is int else value

    result = replace(layout())
    for phase in ("state_before", "state_after"):
        state = result["native_menu_only"][phase]
        state["fixture_root"] = raw_environment["fixture_volume"]["root_path"]
        state["root_identity"] = deepcopy(raw_environment["fixture_volume"]["root_identity"])
        for entry in state["fixture_entries"]:
            entry["file_identity"]["volume_serial"] = \
                raw_environment["fixture_volume"]["root_identity"]["volume_serial"]
    return result
