# DarkReNamer

DarkReNamer is an unofficial, community-maintained Rust port and GitHub fork
of [DarkNamer](https://github.com/nanpuhaha/DarkNamer). It is not an official
release by `darkwalker`, Seo Jang-won, or the upstream repository maintainer.

The first compatibility target is DarkNamer 08.02.10. The local 81,920-byte
reference executable is byte-identical to upstream `DarkNamer v08.02.10.exe`
at commit `3e5d6242e8c8eea60d94e73f8af8ddf9ab677203`, with SHA-256
`ae93ca169d2b69a5cafe7bf835cabb9e45e42ecffa94f41e7cc88f4eec917e34`.
That matched source and resource set defines the compatibility target.

## Current status

The Rust workspace includes a native Win32 compatibility implementation of the
Korean menu, command IDs, bitmap command bars, seven-column ListView, generic
input dialogs, keyboard commands, file and directory admission, sorting,
import/export, and row-order partial-success `MoveFileW` behavior.

Portable transformation and state behavior are covered by automated tests, and
the Windows binary cross-builds from Linux. Native focus and menu timing,
Explorer drag/drop, common dialogs, clipboard operations, cross-parent moves,
and partial-failure behavior still require acceptance on a real Windows host.
Until that evidence exists, releases should be described as compatibility
previews rather than complete parity.

The workspace also retains the preview-first successor implementation with
journaling, recovery, and stricter safety checks. Those improvements are kept
separate from the 08.02.10 compatibility surface.

## Workspace

- `dark-renamer-legacy`: portable UTF-16 list state and DarkNamer 08.02.10
  transformation semantics.
- `darknamer-legacy-app`: native Win32 compatibility shell and `DarkNamer.exe`
  compatibility binary.
- `dark-renamer-core`, `dark-renamer-platform`, `dark-renamer-windows`, and
  `dark-renamer-app`: the later safety-first successor track.

The historical MFC source, screenshots, and archives remain in the current
tree, while the original executables remain available through the fork history
for provenance. They are not Cargo production inputs.

## Development

Run the automated gate:

```text
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
cargo check --workspace --all-targets --all-features \
  --target x86_64-pc-windows-msvc --locked
```

Cross-build the compatibility executable from Linux:

```text
RC=/usr/bin/llvm-rc-19 cargo xwin build --release --locked \
  --target x86_64-pc-windows-msvc \
  -p darknamer-legacy-app --bin DarkNamer
```

## Attribution and license

DarkNamer was originally developed by
[`darkwalker`](https://blog.naver.com/darkwalk77). The upstream Git repository
carries `Copyright (c) 2018 Seo, Jang-won` under the MIT License. The Rust port
adds `Copyright (c) 2026 PiesP` under the same terms.

See `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the package-level notices for the
full attribution and embedded-resource provenance.

Report DarkReNamer bugs in this repository rather than asking the original
DarkNamer maintainers to support this fork. Compatibility reports should state
whether the same behavior occurs in DarkNamer 08.02.10.
