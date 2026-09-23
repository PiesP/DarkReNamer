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
Windows-target check also needs the LLVM resource compiler described below;
set `RC` to its installed path when using a different location. The portable
gate is:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --all-features --locked
RC="${RC:-/usr/bin/llvm-rc-19}" cargo check --workspace --all-targets --all-features \
  --target x86_64-pc-windows-msvc --locked
pwsh -NoLogo -NoProfile -File ./scripts/test-tooling.ps1
```

## Tooling tests

`scripts/test-tooling.ps1` is the tooling test entrypoint for local gates and CI.
`config/tooling-tests.json` declares each test's path, runner, supported platforms,
category, VM requirement and timeout. Discovery checks for missing registrations;
it does not select executable tests. Fixture helpers and the VM CLI have explicit
exclusions. Add or move a test by updating its registry record in the same change.

List the current platform's selection or run a focused category:

```powershell
./scripts/test-tooling.ps1 -List
./scripts/test-tooling.ps1 -Category release
./scripts/test-tooling.ps1 -Id tooling-registry,tooling-bootstrap
```

The runner rejects a platform different from the current host and does not run
VM workloads. It propagates child-process failures and enforces per-test deadlines.
Tests live in `scripts/tests/powershell` and `scripts/tests/python`, with shared
fixtures and path helpers in `scripts/tests/support`. The runner sets Python
import paths only in each test subprocess. `Get-ToolingTestPaths` in `paths.ps1`
and `tooling_test_paths.py` resolve production scripts and repository paths.
Acceptance evidence uses `config/schemas/windows-acceptance-evidence.schema.json`.

## Authenticated tooling modules

Public VM and evidence commands remain in `scripts/`. Their fixed bootstraps
verify pinned loader and manifest bytes before importing implementation modules.
Repository callers start Python with `-I` so environment startup hooks and
unregistered search paths cannot supply code. Direct CLI execution also enters
isolated mode before file-based imports. When invoking a CLI manually, use
`python3 -I scripts/<command>.py`; a script cannot undo interpreter startup hooks
that already ran before its first statement.

Python implementations live under `scripts/darkrenamer_tooling/`: `vm` launches
workloads, `campaign` plans and coordinates runs, `contracts` binds inputs and
source identity, and `evidence` parses and independently verifies observations.
PowerShell definitions live under `scripts/modules/powershell/`, grouped by guest,
UI observer, recovery observer and host controller. Each invocation creates its
own module scope and removes that module after completion.

`config/tooling-bundle.json` declares authorized roles, dependencies, source paths,
flat bundle names and hashes. Checkout paths and retained bundle names are
separate fields. A selected role loads its complete dependency closure from
verified bytes; missing or changed members fail before implementation execution.
Retained evidence is checked against the selected source commit's Git blobs.
Producer summaries do not determine the independent verifier's verdict.

Archive count bounds account for retaining the module closure in every campaign
slot. The canonical limits are in `scripts/darkrenamer_tooling/evidence/archive.py`;
producer packaging uses the same count caps and preserves the separate byte,
compression, and index bounds.

When changing a module, update the explicit inventory in
`scripts/update-tooling-bundle.py` if its role, path or dependencies change. New
roles also require authorization in both `scripts/tooling_bootstrap.py` and
`scripts/tooling-bootstrap.ps1`. Refresh the manifest and public bootstrap pins,
then check that generated files are current:

```bash
python3 scripts/update-tooling-bundle.py
python3 scripts/update-tooling-bundle.py --check
```

The generator rejects unregistered implementation files; it does not discover
new executable roles. Run the tooling gate after refreshing pins. Tooling checks
exercise closure rejection and command compatibility; native execution and the
source-bound VM campaign remain separate validation steps below.

## Linux cross-build

The cross-build path additionally requires `cargo-xwin` and an LLVM resource
compiler compatible with `llvm-rc-19`. Set `RC` when it is not installed at
`/usr/bin/llvm-rc-19`:

```bash
RC=/path/to/llvm-rc-19 cargo xwin build --release --locked \
  --target x86_64-pc-windows-msvc \
  --package darknamer-app --bin DarkReNamer
```

## Native tests in a local Hyper-V VM

Run the current checkout's Windows test binaries on a configured Windows x64
Hyper-V VM through an OpenSSH configuration alias:

```bash
python3 -I scripts/test-windows-vm.py --ssh-host darkrenamer-vm
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

For a trusted helper that supports explicit display geometry, pass
`--desktop-width` and `--desktop-height` together. Without these options, the
helper retains its configured geometry. An explicit request requires matching
dimensions in the helper's lease; it does not itself prove the guest display
size. Small-work-area acceptance must independently record the application's
target-monitor `rcMonitor` and `rcWork`, actual window DPI, and reachable control
bounds. RDP smart sizing and a resized application window are not substitutes.

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
python3 -I scripts/test-windows-vm.py --vm-name "$DARKRENAMER_VM_NAME"
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

### VM-Automated campaign development

[`config/vm-automated-v1.json`](config/vm-automated-v1.json) is the canonical
fixed profile. It declares 22 derived targets and five required gates. The
campaign runner converts those targets into 20 primary execution cells, because
process crash, recovery export and Intent-only candidate discard share one
execution group, then adds 10 independent core-UIA stability executions. The
result is a predeclared 30-slot first-attempt plan.

[`scripts/run-vm-automated-campaign.py`](scripts/run-vm-automated-campaign.py)
uses the common [`scripts/test-windows-vm.py`](scripts/test-windows-vm.py) host
controller for each VM cell. It requires a new absolute output directory outside
the checkout, writes `plan.json` before VM access, runs workloads sequentially
under the one-VM lock, and stops after the first failed attempt. It retains the
partial ledger and diagnostics, but does not retry or replace a failed slot. A
passing campaign must begin again with a new output root and complete plan.

The product checkout, clean harness checkout and eventual hosted
validator checkout must resolve to the same source commit. The campaign reuses
the immutable candidate EXE and records its exact handoff identity. Its native
backend preparation retains source-bound test binaries, the complete actual
stdout/stderr transcripts, result and transport records, and cleanup evidence.

The campaign ZIP is private raw input, not a release verdict. It contains the
complete indexed observations and failed records without normalizing producer
summaries into passes. The repository owner uploads it as the sole asset of the
dedicated private draft ingress release. The hosted validation workflow pins
that release, asset, digest and size; revalidates candidate, source, profile and
all raw evidence; removes its private scratch; and then attests only the
canonical path-free statement. Promotion separately recomputes the statement,
verifies that exact hosted run and attestation, and publishes the unchanged
candidate bytes.

Local tooling checks, a packaged archive, or this documented profile do not
show that the matrix has passed. The VM producer remains trusted to report its
observations honestly; archive validation is not remote VM attestation. Human
visual or comprehensive assistive-technology acceptance, actual IME and
Explorer drag-and-drop, physical-media performance, physical power loss, and VM
reset or storage-fault durability remain outside VM-Automated v1.

## Historical acceptance and GUI diagnostics

Standalone UI and recovery observer staging, the former formal acceptance
matrix, physical-media benchmarks, and the source-bound GUI regression runbook
are retained in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md). They remain
available for interpreting historical evidence and targeted diagnostics; they
do not replace the current VM-Automated campaign above or establish a release
verdict.

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
their shared invocation list. [`config/tooling-tests.json`](config/tooling-tests.json)
is the sole tooling-test registry. Each entry declares its stable ID, path,
runner, supported platforms, category, VM requirement, and per-process timeout.
The suite discovers `test-*.ps1` and `test-*.py` files only to fail when a test
is not registered; its suite entrypoint, fixture helpers, and VM CLI exclusions
are explicit. It never runs VM-backed entries.

Use `-List` to inspect the selected tests without executing them. `-Id`,
`-Category`, and `-Runner` narrow that selection and may be combined:

```powershell
./scripts/test-tooling.ps1 -Platform Ubuntu -List
./scripts/test-tooling.ps1 -Platform Ubuntu -Category vm-automation -Runner Python
./scripts/test-tooling.ps1 -Platform Windows -Id toolchain-consistency
```

Keep independent validators independent unless a shared helper can fail without
weakening both sides of a cross-check. CI and the development gates invoke only
`scripts/test-tooling.ps1`; add or change tooling coverage through the registry.

Candidate creation, promotion, signing policy, checksums, SBOMs, and
attestations are documented in `DISTRIBUTION.md`. Publishing or changing GitHub
repository settings is an explicit release operation, not part of local
development validation.
