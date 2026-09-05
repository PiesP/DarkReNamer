# Development

DarkReNamer pins its Rust toolchain in `rust-toolchain.toml`. Run commands from
the repository root and use the committed lockfile. The project supports three
different validation environments; none substitutes for the others.

## Native Windows development

Install Git, PowerShell 7.4 or newer, and rustup. Opening this repository causes
rustup to select the pinned compiler, `rustfmt`, `clippy`, and the Windows MSVC
target. A Visual Studio Build Tools installation with the current Windows SDK is
also required.

Run the main gate:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
cargo build --release --locked --package darknamer-app --bin DarkReNamer
pwsh -NoLogo -NoProfile -File ./scripts/test-tooling.ps1 -Platform Windows
```

Native tests exercise Windows-only handle and filesystem behavior. They do not
prove interactive desktop, DPI, accessibility, IME, or physical-media
acceptance. Those results must remain external and source-SHA-bound as described
in `SAFETY.md`.

## Portable checks on Linux or WSL

Install PowerShell 7.4 or newer in addition to the pinned Rust toolchain. The
portable gate is:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
cargo check --workspace --all-targets --all-features \
  --target x86_64-pc-windows-msvc --locked
pwsh -NoLogo -NoProfile -File ./scripts/test-tooling.ps1
```

## Linux cross-build and visual diagnostics

The cross-build path additionally requires `cargo-xwin` and an LLVM resource
compiler compatible with `llvm-rc-19`. Set `RC` when it is not installed at
`/usr/bin/llvm-rc-19`:

```bash
RC=/path/to/llvm-rc-19 cargo xwin build --release --locked \
  --target x86_64-pc-windows-msvc \
  --package darknamer-app --bin DarkReNamer
```

`scripts/capture-local-visual-gallery.sh` also requires Wine (`wine`,
`wineboot`, `winepath`, and `wineserver`), Xvfb, ffmpeg, jq, GNU `timeout`, and
`sha256sum`. It is a best-effort diagnostic path, not a CI or Windows acceptance
gate.

## Native tests in a local Hyper-V VM

From WSL, run the current checkout's Windows test binaries on a configured
Windows x64 Hyper-V VM:

```bash
python3 scripts/test-windows-vm.py --vm-name "$DARKRENAMER_VM_NAME"
```

The WSL host needs Python 3.11 or newer, Git, the pinned Rust toolchain,
`cargo-xwin`, `wslpath`, and the LLVM resource compiler described above. Windows
PowerShell must be callable through WSL interop with Hyper-V administration
rights. The VM needs NTFS, the Microsoft Visual C++ x64 runtime, Developer Mode
for non-elevated symlink fixtures, and one unlocked desktop for its local test
account. The test processes run with a limited interactive token; the controller
uses PowerShell Direct only for transport and scheduled-task management. The
runner does not change VM security settings, reset checkpoints, or install tools.

Credentials stay outside the checkout and bundle. By default the controller
loads the host user's local `DarkReNamerVmTools/auth/credential-store.ps1` helper
with `-Action Load`. Use `--credential-helper` to select another trusted local
Windows helper implementing the same `PSCredential` interface. Register the
credential separately under the same Windows host account, using Windows DPAPI
or an equivalent private store. Missing or invalid credentials fail without an
interactive password prompt. GUI login remains a separate prerequisite.

The command requires a clean checkout. It builds all workspace test targets
with locked dependencies, takes executable paths from Cargo's JSON artifacts,
and records their SHA-256 values together with the exact source commit and
lockfile hash. It builds the production EXE separately and copies only the
manifest, runner, and listed binaries into a unique guest test directory.
Tests run sequentially with required backend capabilities enabled; unavailable
capabilities fail the run. Ignored benchmarks remain ignored. Every executable
must produce a libtest summary, and returned counts and log digests are checked
against the collected output. A separate production-app smoke checks window
creation, screenshot capture, and normal exit.

Bundles, logs, and screenshots are external. `--output` selects a new
Windows-backed WSL path; by default the runner uses the Windows host's temporary
directory. A failed binary, timeout, missing output, or incomplete guest cleanup
fails the command. Inspect retained evidence before retrying a failure. Do not
run other GUI automation on the same VM desktop concurrently.

This lane proves actual Windows execution of cross-built test artifacts, not
native Windows compilation or the complete native development gate. It does not
establish the Windows 10/11 DPI and Forced Colors matrix, accessibility/IME,
physical-media benchmarks, or VM power-loss acceptance in `SAFETY.md`.

## Dependency policy

`Cargo.lock` and `--locked` define reproducible application resolution. Exact
manifest pins are reserved for UI/native-boundary dependencies (`rfd`,
`windows`, and `raw-window-handle`), whose updates require focused Windows
validation. Other external dependencies use compatible requirements and remain
fixed by the lockfile. Review changes with the Windows target graph before
altering this policy:

```text
cargo tree --locked --target x86_64-pc-windows-msvc -e features
cargo tree --locked --target x86_64-pc-windows-msvc -d
```

Lockfile package counts include target-specific, build, and development
packages. They are not counts of crates linked into `DarkReNamer.exe`.

## Release tooling

The scripts under `scripts/` form a tested release-validation subsystem. Run
`scripts/test-tooling.ps1` on both Linux PowerShell and Windows before changing
their shared invocation list. Keep independent validators independent unless a
shared helper can fail without weakening both sides of a cross-check.

Candidate creation, promotion, signing policy, checksums, SBOMs, and
attestations are documented in `DISTRIBUTION.md`. Publishing or changing GitHub
repository settings is an explicit release operation, not part of local
development validation.
