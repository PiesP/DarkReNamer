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

## Routine maintenance workflow

1. During edits, run focused Cargo tests or existing tooling selections with
   `-Id` or `-Category`; use `-List` to inspect the selection. Keep external
   `-ResultPath` reports when failure preservation or timings matter.
2. Complete the host-appropriate gate above and merge through the existing
   required `pr-gate/quality`, `pr-gate/unit`, `pr-gate/windows` and
   `pr-gate/security` checks. Use `-Scope All` when runner, shared loaders,
   fixtures or shared contracts affect the remaining registered suites.
3. For release acceptance, freeze one source and immutable candidate, execute
   the source-bound VM campaign below, then independently verify it through the
   existing hosted path. Maintenance CI is not a fresh candidate verdict;
   promotion and publication require separate authorization.
4. Run RuntimeBroker, standalone GUI, Wine/gallery or optimization diagnostics
   only for a concrete investigation, using their existing bounded utilities
   and opt-in scopes. Ambient OS activity alone does not mandate diagnosis or
   create a release requirement. Preserve failures and inspect their evidence
   before a corrective change justifies another workload.

## Tooling tests

`scripts/test-tooling.ps1` is the tooling test entrypoint for local gates and CI.
`config/tooling-tests.json` declares each test's path, runner, supported platforms,
scope, category, VM requirement and timeout. Discovery validates every entry and
checks for missing registrations before applying selection, including tests in
scopes excluded from the run. Registered tests use `test-*` filenames;
fixture helpers use descriptive names without that prefix. The suite and VM CLI
are the only discovery exclusions. Add or move a test by updating its registry
record in the same change.

The default `Current` scope covers current runtime, release and evidence contracts.
`Diagnostics` contains targeted GUI regression and Wine gallery tooling;
`Historical` remains a recognized scope for old registries, but the retired
standalone chain has no current entries; selecting it here fails with no matches.
Reproduce historical tests from the pre-retirement checkout linked below.
Diagnostics are opt-in and remain registered. Use `All` when changing the runner
or shared code that affects every scope. List the current platform's selection or run a
focused scope/category:

```powershell
./scripts/test-tooling.ps1 -List
./scripts/test-tooling.ps1 -Category release
./scripts/test-tooling.ps1 -Id tooling-registry,tooling-bootstrap
./scripts/test-tooling.ps1 -Scope Diagnostics
./scripts/test-tooling.ps1 -Scope All -ResultPath /absolute/external/tooling-results.json
```

`-Category` and `-Runner` narrow the selected scope. An explicit `-Id` selects
those tests across scopes when `-Scope` is omitted; specifying both intersects
the filters. `-List` applies the same selection without executing tests.

The runner rejects a platform different from the current host and does not run
VM workloads. It propagates child-process failures and enforces per-test deadlines.
It reports each attempted script's elapsed time and result and stops at the first
failure. `-ResultPath` writes those results to a new JSON file; choose an absolute
path outside the checkout. Failed and timed-out attempts remain in that report.
Tests live in `scripts/tests/powershell` and `scripts/tests/python`, with shared
fixtures and path helpers in `scripts/tests/support`. The runner sets Python
import paths only in each test subprocess. `Get-ToolingTestPaths` in `paths.ps1`
and `tooling_test_paths.py` resolve production scripts and repository paths.
The current scope includes shared PNG/connection tests and a real evidence CLI
subprocess smoke test on Ubuntu and Windows. The smoke test uses synthetic
archives to check successful canonical output, incomplete-campaign rejection,
exit codes and private extraction cleanup; it does not execute a VM campaign.
The retired standalone acceptance tools and their schema are available only at
the immutable revision linked in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md).

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
source identity, `formats` decodes shared file formats, and `evidence` independently
verifies observations. The campaign and diagnostic GUI use `vm.connection` for
connection profiles and guest preflight. PNG consumers supply separate format,
opacity and resource policies; evidence verification retains expected dimensions
and its cumulative decoded-pixel budget. Sharing format mechanics does not share
producer verdicts with the independent verifier.
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

The VM needs the PowerShell 7.4 or newer SSH subsystem and `sshd`, NTFS with 8.3
short names available for the isolated ProgramData test path, the Microsoft Visual
C++ x64 runtime, Developer Mode for symlink fixtures, and one unlocked
desktop for the same local test account selected by the SSH alias. That account
must be a local administrator, and UAC must provide its linked filtered token.
The controller registers a protected `Interactive` task at `RunLevel Highest`.
Its observer runs elevated in the selected desktop session, while each Rust test
binary and candidate GUI process starts with that user's linked medium-integrity
token. The observer verifies each child token before resuming it. Bundle inputs
and result files are staged under an administrator-owned ProgramData directory;
the user can read them but cannot replace the inputs or forge the trusted result.
This SSH path does not require Hyper-V or administrator rights on the host. The
runner does not change VM security settings, reset checkpoints, or install tools.

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

For the Windows backend target, the elevated observer provides its medium-integrity
test process a short-path alias to the isolated `TEMP` root and prepares the empty
case-sensitive fixture beneath it. The Rust test consumes that fixture with the
linked filtered token; it does not receive elevation or permission to enumerate
other task roots.

The guest creates each Rust test and candidate GUI process suspended, assigns it
to a non-breakaway Windows Job Object with kill-on-close before resuming it, and
keeps that job alive through evidence capture. A passing result requires every
job to be empty and closed. Before starting untrusted test or candidate code, the
controller stages the observer, tooling, input manifest, and candidate bundle
under an administrator-owned ProgramData directory whose DACL grants the runner
account read access only. Each scheduled task has a protected DACL that grants
full access only to SYSTEM and Administrators and read access to its exact runner
SID. The elevated observer protects its process DACL and retains a write handle
to a controller-created result file that the runner account can only read. Rust stdout and stderr are
streamed to bounded files with a 4 MiB per-channel, 8 MiB per-test, and 64 MiB
suite capture limit. The controller passes the remaining suite allowance to
each next test, so captured Rust output cannot exceed 64 MiB across the suite;
after it is exhausted, remaining tests are recorded as failed without launching.
The controller checks result and evidence sizes and aggregate limits before
copying or parsing them on the host.

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

Failed-run preservation and owned-root finalization have a separate, versioned
evidence contract. The controller exclusively writes `original-transport.json`
and `owned-cleanup-strict-failure-preservation.json` outside the disposable guest
roots before requesting deletion. The preservation receipt binds the original
transport, collected files, frozen inventories and original root identities.
The managed launcher closes its desktop lease before writing the nonce- and
hash-bound `owned-cleanup-desktop-closed.json` signal. The controller then records
fresh inventories, held root descriptors and post-deletion observations in
`owned-cleanup-after-strict-failure.json`. Missing evidence, unknown restoration,
changed identities, new inventory entries or cleanup errors refuse finalization.
An independent verifier may establish `owned-clean` from these raw records while
retaining `strict-failed` and `rejected`; the original failure remains immutable.
This handshake does not run for a controller without a matching managed lease,
and it does not authorize a subsequent campaign workload.

This lane proves actual Windows execution of cross-built test artifacts, not
native Windows compilation or the complete native development gate. It does not
establish the Windows 11 DPI and Forced Colors matrix, accessibility/IME,
physical-media benchmarks, or VM power-loss acceptance in `SAFETY.md`.

### VM-Automated campaign development

The campaign runner, native VM backend runner, independent evidence validator,
and hosted wrapper default to the owned-resources
[`config/vm-automated-v2.json`](config/vm-automated-v2.json) profile. Select the
strict [`config/vm-automated-v1.json`](config/vm-automated-v1.json) profile
explicitly when validating historical v1 evidence. Their schema, ID, revision
and source blob digest are distinct. Use `--profile config/vm-automated-v1.json`
for a v1 campaign, `--acceptance-profile-id vm-automated-v1-win11-ntfs` for its
native VM backend, and `--profile-id vm-automated-v1-win11-ntfs` for independent
v1 evidence validation. The hosted workflow dispatch offers an explicit profile
choice and defaults to v2. Each
profile declares the same 22 derived targets and five required gates. The
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
canonical path-free v1 or v2 statement for the selected profile. Promotion
requires its own explicit profile choice, recomputes that statement, checks the
selected source profile and exact hosted run and attestation, and can publish
only the unchanged candidate bytes. A v1 failure or partial campaign cannot be
reinterpreted as v2 success.

Local tooling checks, a packaged archive, or this documented profile do not
show that the matrix has passed. The VM producer remains trusted to report its
observations honestly; archive validation is not remote VM attestation. Human
visual or comprehensive assistive-technology acceptance, actual IME and
Explorer drag-and-drop, physical-media performance, physical power loss, and VM
reset or storage-fault durability remain outside both profiles. V2 verifies
observed product behavior, essential input/focus/settings and owned-resource
cleanup. It does not claim whole-session OS process stasis or explain every
ambient OS lifetime; raw ambient observations remain in the private evidence.

### RuntimeBroker identity diagnostics

[`scripts/diagnose-runtimebroker.py`](scripts/diagnose-runtimebroker.py) executes
one selected attempt from an externally stored, hash-pinned diagnostic plan.
The plan declares at most four attempts and separately pins the unchanged
candidate source/EXE and the clean diagnostic harness source. Use `--help` for
the plan and invocation contract. An exclusive attempt directory prevents a
failed attempt from being replaced or automatically retried.

The observer subscribes to process start/stop events and captures the initial
RuntimeBroker inventory before reporting READY. Managed desktop preparation
starts only after READY. It observes runner lifetimes across sessions through
registration preflight, the original acceptance baselines, the selected UI
workload, strict cleanup, desktop teardown and bounded follow-up. Preparation-only
attempts stop after the original baselines and never launch the candidate.
Diagnostic snapshots and phase journals are separate from acceptance evidence.
This historical utility explicitly retains strict v1 for frozen plans with an
omitted profile; it rejects v2 selection rather than changing the original contract.

Each attempt has a 900-second total budget, with at most 360 seconds of
post-cleanup observation within that budget. The controller reserves time for
its existing cleanup and appearance restoration before starting a candidate.
If a synchronous platform call overruns its cooperative deadline, the attempt
fails its duration bound and further attempts stop; restoration is completed
before owned resources are closed. It is never interrupted merely to report a
successful time bound.

Diagnostic metadata is partitioned into 14 MiB of observer output, 1 MiB of
phase journals and 1 MiB of orchestration metadata. The observer holds at most
64 combined target and parent process handles. WMI delivery, access failures,
processes missed before capture, buffer limits and lifetimes still alive at
observation end remain explicit coverage limits. Same-held-handle wait, native
creation/exit times and exit code establish that a lifetime exited; they do not
establish its termination cause. Package absence and API failure remain distinct.

These records do not change the cleanup allowlist, process singleton rule,
acceptance baseline or any prior failure. Observer readiness or owned cleanup
failure, uncertain restoration, and a duration overrun stop further attempts.
After a strict OS-delta rejection, a separately hash-bound coordinator cleanup
proof may establish only workload-owned cleanup before the next declared
attempt. It cannot replace the original receipt or reclassify acceptance.

### Paired appearance diagnostic

On a clean, committed source checkout with the prepared VM available, run the
opt-in baseline at a supported 1366×768 desktop and 96 DPI:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic appearance-pair \
  --desktop-width 1366 --desktop-height 768 --desktop-dpi 96 \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-appearance-pair-attempt
```

The selected managed RDP helper must support explicit display geometry. The
observer checks the actual target monitor and window DPI before scene capture;
the request alone is not evidence. Other bounded choices are width 800–1920,
height 600–1080, and DPI 96, 120, 144, or 192. Each new attempt needs a new
external output directory. The observer has a 600-second timeout and the
collected output is capped at 120 MiB. The immutable run input records the
existing `vm-automated-v1-win11-ntfs` cleanup profile used by this diagnostic.

The diagnostic retains 66 original guest desktop PNGs. Eight main states
(empty, one unchanged multilingual row, overflow, changed proposal, empty-stem
warning, collision, active selection, and inactive selection) each run
Light → Dark → Light in one process. Five button states (normal, disabled,
hover, held pressed, and keyboard focus), the native View menu, advanced
appearance, and a cancellable prefix prompt are also paired. Button release
outside the enabled Prefix command cancels activation; Apply is never invoked.
The warning uses the valid leaf `.txt`, keeping its empty-stem warning distinct
from an invalid name or collision.

The isolated fixture loads supported persisted user column widths before
startup, so empty and one-row scenes retain horizontal overflow. Native/UIA
state binds process/window, columns, scroll ranges and rectangles, settled focus,
selection, proposed-name cells, enabled states, and unchanged file identities.
After proposal exposure and focus settlement, the fixture uses scalar
`LVM_SCROLL` horizontal pixels to set the same rounded 45% native range position.
The requested and observed pixels must match exactly; UIA percentage rounding
does not relax viewport invariance. Other scenes only observe their viewport.
Main scene captures settle the cursor on the title bar and reject visible owned
tooltips. A retained tooltip is dismissed through standard `TTM_POP` only after
verifying its process and native class, with the dismissal count recorded; a
still-visible overlay rejects capture. Interaction captures intentionally retain
their target state. Dialog
Cancel and appearance-setting rollback are checked without applying file changes.
The custom prompt default is queried on its bound standard BUTTON through
`WM_GETDLGCODE` and `GetDlgCtrlID`; the prompt uses `DefWindowProcW`, so a
`DM_GETDEFID` dialog-manager response is not assumed.

Both native scrollbar thumbs are pressed, moved, and released in each theme phase.
The observer binds the hit HWND and native mouse capture to the list, records
`SCROLLBARINFO` components and `SCROLLINFO`, verifies that dragging advances the
viewport, and restores the initial position in `finally`. The additional 18
original PNGs support separate dark thumb/track/intersection assertions. Flat
regions require at least 95% of pixels within two RGB units of their declared
role; native thumb states can select normal, hot, pressed, or disabled roles.
The two Light endpoint client rasters must restore with no pixel differences
of ten RGB units or more. These checks cover the declared configuration, not
unexecuted native themes or display configurations.

The pair records the target window's actual DPI-awareness context and screen-space
client bounds separately from observer awareness. Each theme phase rechecks both
and the system message/status `LOGFONTW` recipes at the target DPI. Installed
font-family count and an ordinal, UTF-8 inventory digest describe the font
environment. These recipes describe system font inputs, not a cross-process
`HFONT` inspection; original multilingual glyph rasters remain the rendering
evidence. No application GDI handle is dereferenced by the observer.

The independent verifier checks source/EXE/environment bindings, exact capture
inventory, state invariance, proposed-name semantic pixels, selection transitions,
and button-state pixel differences. Scrollbar pixels remain a diagnostic
measurement until the native-chrome conformance and interaction checks are
completed. Forced Colors, system-theme following, and the DPI/text-size matrix
are separate outstanding checks. This opt-in diagnostic does not complete the
four fixed GUI regression runs or release acceptance.

The painting policy keeps control outlines, default outlines, and decorative
hairlines one physical pixel. Focus inset, pressed displacement, and existing
separator slots/padding scale in DIP. Adjacent buttons share one outline seam;
allocated separator slots are cleared and contain one centered hairline.
Interactive outlines use `control_outline`; header, status, group and dialog
separators use `divider_subtle`. Disabled labels use the distinct readable
`text_disabled` role. Native focus rectangles and selected-row precedence are
retained. Dark scrollbar tracks use the window surface, with a stronger thumb
ramp from the existing outline/foreground roles; native geometry and input remain
owned by the ListView. Native/Forced Colors disables this custom chrome.

## Historical acceptance and GUI diagnostics

Standalone UI and recovery observer staging, the former formal acceptance
matrix, physical-media benchmarks, and the source-bound GUI regression runbook
are retained in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md). They remain
available for interpreting historical evidence and targeted diagnostics; they
do not replace the current VM-Automated campaign above or establish a release
verdict.

GUI/Wine tooling tests use the explicit diagnostic scope described in
[Tooling tests](#tooling-tests). Historical standalone tests are retired;
reproduce them from the linked pre-retirement revision. Keep the Wine gallery as
a diagnostic fallback only when the prepared VM cannot perform the required check.

The planning benchmark and binary/profile matrix workflows are manually dispatched
experiments. Use the representative planning measurement when investigating the
current settings, and run optimization matrices only when reconsidering those
choices. Their results do not replace source-bound Windows or release validation.

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
the applicable [tooling scopes](#tooling-tests) on both Linux PowerShell and
Windows when changing shared invocation or platform-sensitive behavior.

Keep independent validators independent unless a shared helper can fail without
weakening both sides of a cross-check. CI and the development gates invoke only
`scripts/test-tooling.ps1`; add or change tooling coverage through the registry.

Candidate creation, promotion, signing policy, checksums, SBOMs, and
attestations are documented in `DISTRIBUTION.md`. Publishing or changing GitHub
repository settings is an explicit release operation, not part of local
development validation.
