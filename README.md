# DarkReNamer

DarkReNamer is an unofficial, community-maintained Rust port and GitHub fork
of [DarkNamer](https://github.com/nanpuhaha/DarkNamer). It is not an official
release by `darkwalker`, Seo Jang-won, or the upstream repository maintainer.

The port targets DarkNamer 08.02.10. The external 81,920-byte
reference executable is byte-identical to upstream `DarkNamer v08.02.10.exe`
at commit `3e5d6242e8c8eea60d94e73f8af8ddf9ab677203`, with SHA-256
`ae93ca169d2b69a5cafe7bf835cabb9e45e42ecffa94f41e7cc88f4eec917e34`.
That matched source and resource set defines the compatibility target.

## Current status

The Rust workspace provides a native Win32 implementation of the Korean menu,
command IDs, native command rails, a ListView with seven persisted data columns
and a fixed status column, input dialogs, keyboard commands, bounded file and
directory admission, sorting, and import/export. The UTF-16 name transformations
retain DarkNamer 08.02.10 compatibility, while Apply uses the maintained safe
execution path.

Apply validates Windows leaf names and current file identities before showing
confirmation. It executes local same-folder renames with handle-relative,
no-replace operations, including case-only changes and rename cycles. A bounded
write-ahead journal records intent before mutation, supports reverse rollback,
and blocks further Apply operations when an interrupted state cannot be safely
reconciled. Network paths, reparse traversal, case-sensitive directories, and
cross-folder moves are rejected by the current safe policy.

Portable transformation and state behavior are covered by automated tests, and
the Windows binary cross-builds from Linux. Native focus and menu timing,
Explorer drag/drop, common dialogs, clipboard operations, native startup
recovery, and interactive failure handling still require acceptance on a real
Windows host.
Until that evidence exists, releases should distinguish source-complete porting
from manually verified runtime parity.

## Appearance and local settings

The **View** menu provides System, Light, and Dark appearance modes. System is
the default and follows the Windows app color setting when it can be queried;
otherwise DarkReNamer leaves native rendering under Windows control. Forced
Colors and an unavailable high-contrast query always take precedence over the
stored appearance and disable custom colors.

DarkReNamer applies its Light and Dark palettes to the main workbench, native
menus, command buttons, list headers, status surfaces, and the advanced
appearance window. App-owned input prompts use the same palette while retaining
standard Windows edit, combo-box, and button controls. File dialogs and
confirmation TaskDialogs continue to use Windows rendering. Forced Colors keeps
system colors and native focus and selection precedence across every surface.

Advanced appearance controls are intentionally under **View > Appearance**.
They offer semantic density and emphasis presets plus separator, changed-name
background highlight, and empty-state safety-copy visibility. They do not affect the rename model,
Apply authorization, journal, recovery state, or Undo data.

The runnable product remains one `DarkReNamer.exe`. Column and appearance
preferences are stored below `%LOCALAPPDATA%\DarkReNamer`; no configuration
sidecar is required beside the executable.

## Workspace

- `darknamer-core`: portable UTF-16 list state and DarkNamer 08.02.10
  transformation semantics.
- `darknamer-app`: native Win32 application and `DarkReNamer.exe` binary.

The current tree contains only the Rust implementation and its build metadata.
Historical MFC source, screenshots, archives, and executables remain available
through the fork history and upstream repository for provenance.

The filesystem transaction and recovery contract is documented in
[`SAFETY.md`](SAFETY.md). Tagged Windows prereleases, unsigned artifact status,
checksums, SBOMs, attestations, and the future signing boundary are documented
in [`DISTRIBUTION.md`](DISTRIBUTION.md).

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
  -p darknamer-app --bin DarkReNamer
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
