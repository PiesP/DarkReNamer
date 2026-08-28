# Dark Renamer

Dark Renamer is a Windows-first native batch-renaming workbench written in Rust.
It independently reimplements the useful workflows observed in the local legacy
`DarkNamer.exe` while replacing ambiguous destructive behavior with a preview,
collision checks, explicit confirmation, and recoverable transactions.

## Status

The initial Rust successor is functional. It provides native file selection and
drag/drop, non-recursive folder admission, ordered rename rules, a before/after
preview with structured blockers, exact-count Apply confirmation, durable
recovery journals, and transaction-bound Undo.

Filesystem mutation is enabled only in Windows builds, where an audited native
adapter binds each rename to retained parent/source handles and performs an
atomic no-replace operation. Other targets remain useful preview-only builds.
The legacy executable is behavior evidence, not a source dependency, and is
intentionally not stored in this repository.

## Architecture

- `dark-renamer-core`: platform-independent rules and deterministic planning.
- `dark-renamer-platform`: filesystem admission, verified execution, journals,
  recovery, and Undo.
- `dark-renamer-windows`: audited Windows handle and file-identity adapter.
- `dark-renamer-app`: native `eframe`/`egui` desktop workbench.

The UI does not rename paths directly. It asks the platform service to plan and
execute operations, and Apply remains unavailable whenever a preview row is
blocked.

## Development

Run the native workbench:

```text
cargo run -p dark-renamer-app --bin dark-renamer --locked
```

Run the automated validation gate:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
cargo check --workspace --all-targets --all-features --target x86_64-pc-windows-msvc --locked
```

Windows-native behavior must additionally be executed on a Windows host. A
Linux build or Windows cross-check does not prove NTFS/ReFS identity semantics,
case-only renames, interruption recovery, Explorer drag/drop, accessibility, or
packaged GUI behavior.
