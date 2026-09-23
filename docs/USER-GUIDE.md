# User guide

This guide covers the native Korean-language DarkReNamer interface. For the
supported operating-system and filesystem boundary, read the
[README](../README.md#supported-environment). The
[safety model](../SAFETY.md) remains authoritative for mutation and recovery.

## Add and review entries

Start DarkReNamer normally, without administrator elevation. Use **파일 추가...**
(Add files) to add entries within the supported scope. Choose a name
transformation and review both the proposed name and the Status column before
Apply.

Blue emphasis identifies planned names, amber identifies warnings, and red
identifies blocked names. Status text carries the same meaning without relying
on color. Select one row and open **보기 > 선택 항목 진단...** (View > Selected
item diagnostics) to read the complete explanation, source and proposed path,
and corrective action. The diagnostic is a synchronized model preview; it does
not check live filesystem occupancy or authorize Apply.

## Set or reset a target folder

Use **편집 > 대상 폴더 > 모든 파일의 대상 폴더 지정...** (Edit > Target folder
> Set the target folder for all files) to propose moving regular files to an
existing directory on the same local NTFS volume. This command is unavailable
when any row is a directory. Review the rebuilt path, collision, Status, and
Apply-readiness previews after choosing the folder.

**편집 > 대상 폴더 > 대상 폴더 변경 취소** resets destination parents to the
original parents while keeping proposed names. **편집 > 모든 이름 변경 취소**
resets proposed names while keeping destination parents. Both commands change
the proposal only. Neither command reverses a filesystem operation that has
already completed.

## Apply a proposal

Choose **변경 적용** (Apply) after reviewing every row. DarkReNamer reopens and
revalidates sources, parents, identities, names, destinations, and the selected
scope before it shows the final confirmation. The confirmation separates
rename-only, move-only, and combined changes and states that existing
destinations are not overwritten.

Cancelling the confirmation leaves files unchanged. Cancellation after
execution begins is observed only between complete primitive steps and may
start journaled rollback. The progress window reports the outcome that actually
occurred; acknowledging a cancellation request does not promise that rollback
has already completed.

## Appearance

The **보기** (View) menu provides System, Light, and Dark appearance modes.
System is the default and follows the Windows app color setting when it can be
queried. Forced Colors, or an unavailable high-contrast query, takes precedence
over the stored appearance and disables custom colors.

DarkReNamer applies its Light and Dark palettes to the main workbench, command
buttons and Tooltips, list headers and information tips, status surfaces, the
menu, app-owned input prompts, and the advanced appearance window. Native
System and Forced Colors surfaces, file dialogs, and confirmation TaskDialogs
continue to use Windows rendering.

App-owned fonts combine the Windows text-size preference with monitor DPI. If
the preference cannot be queried, DarkReNamer keeps the normal system font
size. Windows-owned TaskDialogs retain the operating system's text-sizing
behavior.

The file list keeps the native Windows ListView style, including system-rendered
scrollbars that may appear light in Dark mode. The advanced appearance window
separately requests a dark native theme for its scrolling body and falls back
to system rendering when unavailable. Native scrolling, focus, selection, and
accessibility behavior are retained.

## Advanced appearance settings

Open **보기 > 모양 설정...** (View > Appearance settings) to configure semantic
density and emphasis presets, separators, changed-name background highlighting,
and empty-state safety-copy visibility. Reset, OK, and Cancel remain in a fixed
footer while the settings body scrolls at narrow work-area sizes, large system
fonts, and high DPI.

Appearance settings affect presentation only. They cannot change proposed
names, model revisions, Apply authorization, journal capabilities, mutation or
recovery locks, or recovery data.

Column and appearance preferences are stored under
`%LOCALAPPDATA%\DarkReNamer`. The portable executable does not need a
configuration sidecar, but preferences remain associated with the current
Windows user when the executable is moved or replaced. A preference load or
write failure uses safe presentation defaults.

## Recovery after interruption

If DarkReNamer finds a retained journal at startup, it can open in recovery
lock before changing any selected file. With one valid active journal, the
recovery window defaults to Cancel and requires an explicit confirmation before
reconciling current identities and attempting reverse-order rollback.

Keep Apply locked and preserve the journal evidence when the application reports
both active and candidate journals, corrupt or torn content, an uncertain
promotion, or another ambiguous state. Do not rename, move, edit, or delete the
journal files to force the workbench to unlock.

Diagnostic export copies retained journal evidence to new files without
overwriting an existing destination. Store exported evidence privately: it can
contain local paths and filesystem identity data. Report the failure in this
repository with the displayed stage, structured kind, native code, codec frame,
and observed size. Do not send it to the original DarkNamer maintainers.

For the full journal state machine, cleanup rules, and corrupt-evidence policy,
read [Startup recovery and corrupt evidence](../SAFETY.md#startup-recovery-and-corrupt-evidence).

## Known limitations

- The interface is Korean even when this guide is reached through an English or
  Japanese README.
- Native System, Forced Colors, file dialogs, confirmation TaskDialogs, and
  native scrollbars follow Windows and may not match the app-owned Light or Dark
  palette.
- The model preview cannot certify the current filesystem; Apply always performs
  a fresh validation.
- Proposal reset is not filesystem Undo.
- The supported scope excludes cross-volume and directory moves, destination
  creation, replacement, folder merging, non-NTFS filesystems, network or device
  paths, case-sensitive directories, elevated execution, and reparse traversal.
