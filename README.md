# Dark Renamer

Dark Renamer is a Windows-first native batch-renaming workbench written in Rust.
It independently reimplements the useful workflows observed in the local legacy
`DarkNamer.exe` while replacing ambiguous destructive behavior with a preview,
collision checks, explicit confirmation, and recoverable transactions.

## Status

The repository is under active reconstruction. The initial compatibility target
is file admission, ordered rename rules, before/after preview, safe Apply, and
Undo. The legacy executable is evidence for behavior, not a source dependency,
and is intentionally not stored in this repository.

## Architecture

- `dark-renamer-core`: platform-independent rules and deterministic planning.
- `dark-renamer-platform`: filesystem admission, verified execution, journals,
  recovery, and Undo.
- `dark-renamer-app`: native `eframe`/`egui` desktop workbench.

The UI does not rename paths directly. It asks the platform service to plan and
execute operations, and Apply remains unavailable whenever a preview row is
blocked.

## Development

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
```

Windows-native behavior must additionally be checked on a Windows host. A Linux
build or a Windows cross-check does not prove Explorer drag/drop, filesystem
identity, case-only renames, accessibility, or packaged GUI behavior.

