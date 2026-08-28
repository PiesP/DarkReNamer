# Legacy behavior inventory

This inventory binds the first Rust implementation to static evidence from the
local binary identified in `reference/binary-baseline.toml`. It distinguishes
observed behavior from safety choices made by the successor.

## Observed static evidence

The binary is a 32-bit Unicode MFC application importing `MFC42u.DLL`,
`MSVCRT.dll`, and `MSVCP60.dll`. Its resources contain a main dialog with a
`SysListView32`, a two-field input dialog, two 13-button toolbars, menus, icons,
and bitmaps.

The imported Windows APIs establish these capabilities:

- Explorer file drag/drop and a native folder browser.
- File attribute, size, creation-time, and modification-time inspection.
- Rename through `MoveFileW`.
- Name comparison through `CompareStringW`.

Menu resources expose the following user operations:

- Add files, clear/sort the path list, move rows up/down, and edit a name.
- Replace text; add a prefix or suffix; remove a name, position, or delimited
  segment; retain digits; pad digits; and add sequence numbers.
- Remove, add, or replace extensions; add text before/after a path; and normalize
  paths.
- Import/export proposed names and paths through text files or the clipboard.
- Toggle full path, size, modification time, and creation time columns.
- Apply actual changes and restore original names.

## Successor contract

Static evidence does not establish the legacy collision, overwrite, cycle,
atomicity, or recovery semantics. Dark Renamer therefore does not reproduce
those unknowns. The successor contract is:

1. Build an immutable before/after plan.
2. Block invalid names, duplicate targets, occupied destinations, stale sources,
   and unsupported path relationships.
3. Require explicit confirmation of the exact changed-item count.
4. Persist transaction intent before the first filesystem mutation.
5. Use no-replace operations and temporary sibling names for cycles.
6. Offer recovery and Undo only after identity revalidation.

Runtime parity remains unverified until the legacy MFC dependency is available
in a disposable Windows test environment. No claim in this document depends on
runtime observation.
