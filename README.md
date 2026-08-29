# DarkNamer

This repository first reproduces the local `DarkNamer.exe` 08.02.10 application
as a native Rust/Win32 program. The compatibility source is the byte-matched
original executable, source, and resources recorded in
`reference/binary-baseline.toml`.

## Status

The default compatibility binary is `DarkNamer.exe`. It implements the Korean
menu and command IDs, original bitmap command bars, seven-column native
ListView, status bar, generic input dialogs, keyboard shortcuts, file/directory
admission, recursive folder choice, transformations, sorting, column toggles,
clipboard and text import/export, and row-order partial-success `MoveFileW`
Apply behavior.

The existing preview-first `dark-renamer` eframe application remains in the
workspace for the later improvement phase. Its journal, recovery, and stricter
safety behavior are not mixed into the default 08.02.10 compatibility surface.
The original executable itself is intentionally not tracked here.

## Architecture

- `dark-renamer-legacy`: portable UTF-16 list state and exact transformation
  semantics from DarkNamer 08.02.10.
- `darknamer-legacy-app`: default native Win32 compatibility shell and
  `DarkNamer.exe` binary.
- `dark-renamer-core`: platform-independent rules and deterministic planning.
- `dark-renamer-platform`: filesystem admission, verified execution, journals,
  recovery, and Undo.
- `dark-renamer-windows`: audited Windows handle and file-identity adapter.
- `dark-renamer-app`: native `eframe`/`egui` desktop workbench.

The latter four crates belong to the later successor track; compatibility
behavior is owned by the two legacy crates.

## Development

Cross-build the compatibility executable from Linux:

```text
RC=/usr/bin/llvm-rc-19 cargo xwin build --release --locked \
  --target x86_64-pc-windows-msvc \
  -p darknamer-legacy-app --bin DarkNamer
```

The output is
`target/x86_64-pc-windows-msvc/release/DarkNamer.exe`.

Run the automated validation gate:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
cargo check --workspace --all-targets --all-features --target x86_64-pc-windows-msvc --locked
```

Windows-native behavior must additionally be executed on a Windows host. A
Linux build or Windows cross-check does not prove native menu/focus timing,
Explorer drag/drop, common dialogs, clipboard behavior, folder recursion,
cross-parent directory moves, or partial-failure Apply behavior.
