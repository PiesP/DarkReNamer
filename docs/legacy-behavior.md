# DarkNamer 08.02.10 compatibility contract

This document defines the first Rust milestone: reproduce the behavior and
native information architecture of the local `DarkNamer.exe` before adding
product improvements.

## Authoritative evidence

The local executable and the upstream `DarkNamer v08.02.10.exe` at the commit
recorded in `reference/binary-baseline.toml` are byte-identical and share SHA-256
`ae93ca169d2b69a5cafe7bf835cabb9e45e42ecffa94f41e7cc88f4eec917e34`.
The matching MFC source and resources are therefore the compatibility source of
truth rather than inferred static evidence.

The relevant upstream files are `DarkNamerDlg.cpp`, `DarkNamerDlg.h`,
`DlgInput.cpp`, `DarkNamer.rc`, and `resource.h` under
`archives/darknamer_code_080210`.

## Native surface

- Window caption: `DarkNamer`; initial dialog template: 227×218 DLU with
  resizable frame, menu, Explorer drop target, and 10-point MS Sans Serif.
- Runtime layout: 44-pixel left toolbar, central report-mode ListView,
  44-pixel right toolbar, and an 18-pixel sunken status bar.
- Default visible columns: `현재이름`, `바꿀이름`, and `파일위치`. Optional
  columns are `전체경로`, `파일크기`, `변경시각`, and `생성시각`.
- Menus: `파일`, `편집`, `보기`, `기능`, and the root `버전` command.
- The generic `입력창` dialog has two conditional edit fields, an optional
  dropdown, `확인`, and `취소`.

## List and command behavior

- File picker, Explorer drop, and path-list import append to the current list.
  Duplicate paths are skipped case-insensitively. Files and directories are
  both accepted; adding a directory follows the original recursive/direct
  choice.
- `Delete` removes selected rows. `<` and `>` move selected rows. Double-click
  performs direct proposed-name editing.
- `Ctrl+Z` resets proposed names to the current original names; it is not a
  filesystem Undo command.
- View commands toggle optional columns. Sorting provides ascending/descending
  modes for name, full path, size, modification time, and creation time.
- Clipboard/text import and export retain list order and the original
  blank-line behavior.

## Name transformation behavior

- String replacement operates on the complete proposed name, including the
  extension. Prefix insertion also precedes the complete name; suffix insertion
  occurs immediately before the extension for files.
- Name clearing preserves only the extension. Position deletion is 1-based and
  inclusive, with a separate delete-from-end mode. Delimiter deletion removes
  the first matched start/end pair including both delimiters.
- Number-only retains ASCII digits in the stem. Digit padding affects only the
  first or last digit run selected by the dialog.
- Sequence numbering supports front/back placement and front/back placement
  with numbering restarted when the parent path changes.
- Extension delete/add/replace follows the original first-dot/last-dot rules,
  including its dotfile behavior. Directories do not have extensions.
- Parent-folder text can be inserted before or after the proposed name. Path
  unification changes every row's destination root.

## Apply behavior

Apply performs the original confirmation and validation sequence: empty-name
check, duplicate final-path check, confirmation, then row-order `MoveFile`
attempts. Successful rows update their current path/name state. Failures remain
in the list and are reported using the original partial-success model.

Journaled execution, exact-count confirmation, recovery, case conversion, and
other successor improvements are later-stage capabilities. They must not alter
the default DarkNamer 08.02.10 compatibility surface until parity is complete.

## Acceptance boundary

Portable transformation and list-state behavior must be covered by golden
tests derived from the matched source. Native menu/layout, file and directory
admission, cross-parent moves, partial failures, Explorer drag/drop, and common
control behavior require execution on a Windows host. Cross-compilation alone
does not prove those semantics.
