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

Run the current checkout's Windows test binaries on a configured Windows x64
Hyper-V VM through an OpenSSH configuration alias:

```bash
python3 scripts/test-windows-vm.py --ssh-host darkrenamer-vm
```

The default `--desktop-mode rdp` starts a managed RDP desktop before the SSH
controller runs and disconnects its client after the controller finishes,
including failures. It requires WSL Windows interop and a separately configured
Windows host helper at
`%LocalAppData%\DarkReNamerVmTools\rdp\desktop-session.ps1`.
Use `--desktop-helper` to select another trusted Windows helper. The helper's
private local profile must bind the selected SSH alias or VM name to the expected
guest account and authenticated RDP endpoint. Provision its certificate trust,
restricted network access, and private credential store separately; credentials
and endpoint configuration stay outside this repository and its bundles.
For the local self-signed listener, install its verified public certificate in
the Windows host's `LocalMachine\Root` store during administrator setup;
`CurrentUser\Root` alone did not establish RDP trust on the prepared host.
Normal test runs use the unprivileged helper and do not require elevation.

`--desktop-scale` selects the RDP scale; its default is 200 percent. The runner
checks the production window's actual DPI against that request. Use
`--desktop-mode existing` for a separately prepared active, unlocked desktop,
including console-specific acceptance or hosts without Windows interop. There
is no automatic fallback when managed RDP preparation fails.

The Linux or WSL host needs Python 3.11 or newer, PowerShell 7.4 or newer, Git,
the pinned Rust toolchain, `cargo-xwin`, and the LLVM resource compiler described
above. The alias must resolve through the host user's OpenSSH configuration to a
key-authenticated VM account, and the VM host key must already be pinned in the
host user's `known_hosts`. The controller enforces batch mode, strict host-key
checking, and disabled agent forwarding; it never prompts for a password. Put
the user, key, address, port, and any IPv6 syntax in the OpenSSH configuration,
not in `--ssh-host`.

The VM needs the PowerShell 7.4 or newer SSH subsystem and `sshd`, NTFS, the Microsoft
Visual C++ x64 runtime, Developer Mode for non-elevated symlink fixtures, and one
unlocked desktop for the same local test account selected by the SSH alias. That
VM account must be a local administrator because the controller registers and
manages the scheduled task. The task itself uses `Interactive` logon and
`RunLevel Limited`, and the guest runner rejects an elevated token. This SSH path
does not require Hyper-V or administrator rights on the host. The runner does
not change VM security settings, reset checkpoints, or install tools.

PowerShell Direct remains available from WSL when the Windows host process has
Hyper-V administration rights:

```bash
python3 scripts/test-windows-vm.py --vm-name "$DARKRENAMER_VM_NAME"
```

Automation can additionally pass `--expected-vm-id <GUID>` to require that exact
Hyper-V VM identity and name. The controller resolves and rechecks the GUID,
connects PowerShell Direct by GUID, and verifies the returned transport identity.
Without the optional GUID, it first resolves one exact VM name and pins that
resolved GUID for the session.

PowerShell Direct credentials stay outside the checkout and bundle. By default
that transport loads the Windows host user's local
`DarkReNamerVmTools/auth/credential-store.ps1` helper with `-Action Load`. Use
`--credential-helper` with `--vm-name` to select another trusted local Windows
helper implementing the same `PSCredential` interface. Register the credential
separately under the same Windows host account, using Windows DPAPI or an
equivalent private store. Missing or invalid credentials fail without an
interactive password prompt. With `--desktop-mode existing`, GUI login remains
a separate prerequisite.

The command requires a clean checkout. It builds all workspace test targets
with locked dependencies, takes executable paths from Cargo's JSON artifacts,
and records their SHA-256 values together with the exact source commit and
lockfile hash. It builds the production EXE separately and copies only the
manifest, runner, and listed binaries into a unique guest test directory.
Tests run sequentially with required backend capabilities enabled; unavailable
capabilities fail the run. Ignored benchmarks remain ignored. Every executable
must produce a libtest summary, and returned counts and log digests are checked
against the collected output. The production EXE lane checks window creation,
then drives the native file picker, prefix prompt, preview, and Apply task dialog
through UI Automation. It first cancels Apply and proves the fixture is unchanged,
then confirms the exact destructive action and proves the on-disk rename preserved
the file contents and NTFS identity without journal residue. The lane retains
source-bound preview and confirmation screenshots before closing normally.

Bundles, logs, and screenshots are external. `--output` selects a new absolute
external path. By default SSH uses the Linux host's temporary directory, while
PowerShell Direct uses the Windows host's temporary directory and requires a
Windows-backed WSL path. A failed binary, timeout, missing output, or incomplete
guest cleanup fails the command. Inspect retained evidence before retrying a
failure. The guest runner holds a session-local, cross-process desktop lock for
the suite and fails when another controller is using that interactive desktop.
For the suite's lifetime, its runner also requests that Windows keep the system
and display awake, then restores the thread's previous execution-state flags.
The controller verifies that the desktop is active and unlocked; a disconnected
Explorer session does not qualify. Managed RDP also binds that desktop account
to the helper's expected guest SID.

This lane proves actual Windows execution of cross-built test artifacts, not
native Windows compilation or the complete native development gate. It does not
establish the Windows 11 DPI and Forced Colors matrix, accessibility/IME,
physical-media benchmarks, or VM power-loss acceptance in `SAFETY.md`.

## Interactive acceptance observers

The optional `scripts/windows-vm-acceptance.ps1` and
`scripts/windows-vm-recovery-acceptance.ps1` observers reuse an existing VM test
bundle. Stage the unchanged manifest, runner, and listed binaries in a private
`bundle` directory, with the selected observer in its parent directory. Record
the observer's SHA-256 separately from the bundle's source and executable
digests. Run one observer at a time in the bundle account's unlocked,
non-elevated Windows PowerShell desktop session, passing `-BundleRoot`,
`-ExpectedSessionId`, `-OutputRoot`, and `-ExpectedScriptSha256` explicitly.
Both observers verify those bindings and acquire the shared desktop lock.

The UI observer requires a new output directory. It records the actual window
DPI, UI Automation metadata, keyboard-only file import and prefix entry,
Apply cancellation and confirmation, disk contents and identities, and normal
close. Screenshots require operator review before a UI cell can be accepted.
`-HighContrast` temporarily enables Windows High Contrast and verifies restoration
of the original flags, scheme, system colors, and active visual-style path, color,
and size. The private rescue snapshot retains that complete identity while public
acceptance output exposes only its artifact hash. Arrange a separate interactive
rescue invocation with `-RestoreHighContrastOnly` and the same arguments before
starting that mode; retain the observer and snapshot until restoration is verified.

The recovery observer requires an existing output directory and creates a unique
child. `-Mode ProcessCrash` stops only its production application after observing
a partial fixture rename, then relaunches it with the same journal and profile.
It checks that startup leaves files unchanged before explicit recovery, and that
recovery restores names, contents, identities, and clean journal state.
`WorkerCancellation` and `WorkerClose` instead exercise the enabled cancel
control or ordinary close during a partial transaction. A missed interruption
boundary fails the run. `-FixtureCount` controls the workload; its encoded path
list must fit the application's import limit.

Collect and hash-check all external output before removing a successful session.
Retain failed-session evidence for diagnosis. These observers do not reset the VM,
provide storage-fault evidence, change DPI settings, or certify the full acceptance
matrix. Transfer reviewed observations into a separate draft using `SAFETY.md`;
do not merge observations from different Windows builds into one operator context.

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
