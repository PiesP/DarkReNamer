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

The Rust dependency-audit job in `.github/workflows/security.yaml` runs on its
weekly schedule and by manual dispatch, including when source is unchanged.
CI retains the pull-request, push, and merge-group dependency gate. The
scheduled job caches pinned scanner binaries only; each run refreshes advisory
data and checks the selected `Cargo.lock` and dependency policy anew. A failed
refresh or scan is a failed check, not a clean result.

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

## Tooling command ownership (issue #57, base `b691535b78c350d6fcbdb0afa73489e87c63bc23`)

Python owns portable planning, parsing and verification; PowerShell owns host,
guest, Hyper-V, UI Automation and Windows release integration. These are owners,
not interchangeable runtimes. At the issue base, the tracked `scripts/` tree contained
67 Python, 76 PowerShell (`.ps1`/`.psm1`) and two Bash files, including tests and
fixtures. The nine workflow YAML files also contain handwritten Bash/default
shell and PowerShell steps; moving those lines into YAML does not remove their
language. Ten PowerShell module files contain embedded C# (`Add-Type`):
`controller-entry.psm1`, `guest-native.ps1`, `guest-process.ps1`,
`guest-runtime.ps1`, `recovery-journal.ps1`, `recovery-native.ps1`,
`recovery-scenarios.ps1`, `runtimebroker-observer.ps1`, `ui-application.ps1`
and `ui-native.ps1`. This is a file count, not a count of C# blocks.
The C# is a separate CLR/native-interop requirement, not PowerShell syntax or
generated JavaScript. Product Rust and workflow configuration are outside these
script-language counts. The source-metadata and release-file extractions each
add one PowerShell helper and one registered PowerShell test, bringing the
PowerShell count to 80. Python, Bash and embedded-C# file counts remain
unchanged. The release-file extraction removes its inline producer.

The table names public command families and their effects; the complete test
selection, platforms, scope and deadlines stay in
[`config/tooling-tests.json`](config/tooling-tests.json). The authorized module
roles, source/bundle names and dependencies stay in
[`config/tooling-bundle.json`](config/tooling-bundle.json), with campaign profiles
in `config/vm-automated-v1.json` and `config/vm-automated-v2.json`. Do not add a
second command or asset registry.

| Command / implementation | Runtime and stage; input | Output or side effect; verification |
| --- | --- | --- |
| `test-tooling.ps1` / PowerShell runner | PowerShell 7.4+ on actual Linux or Windows; registry `-Scope`, `-Id`, `-Category`, `-Runner`, `-List` | Validates discovery before selection, invokes registered subprocesses with timeout, returns failure status and optional external result JSON. CI calls it on Ubuntu/Windows; `tooling-registry` tests selection. |
| `update-tooling-bundle.py` / Python generator | Python 3.11+ in the checkout; explicit source inventory and `--check` | Regenerates bundle manifest and wrapper pins, or reports drift without writes under `--check`; `tooling-bundle` and `tooling-bootstrap` tests cover closure and rejection. |
| `tooling_bootstrap.py`, `tooling-bootstrap.ps1` / private authenticated loaders | Isolated Python or PowerShell 7.4+ after a public wrapper checks the pinned loader bytes; fixed manifest, role and layout | Validate and hold the required module closure, then expose verified import/scriptblock APIs. Bootstrap and bundle tests cover tampering, layouts and missing roles; neither loader is a general public CLI. |
| `test-windows-vm.py`, `run-vm-automated-campaign.py` / Python `vm` and `campaign` modules | Isolated Python on host/WSL, prepared VM connection, selected profile/source/candidate | Prepare and run source-bound native tests/campaigns, producing private bundles and receipts; registered VM, campaign, authority and cleanup tests cover contracts. Actual VM evidence is a separate gate. |
| `run-gui-regression.py`, `diagnose-runtimebroker.py` / Python `vm.gui` and diagnostic modules | Isolated Python on host/WSL, selected candidate and prepared VM; explicit diagnostic options | Produce bounded GUI or RuntimeBroker diagnostic evidence. GUI/RuntimeBroker diagnostic tests are opt-in; neither command publishes acceptance by itself. |
| `validate-gui-regression-evidence.py`, `validate-vm-automated-evidence.py`, `validate-vm-automated-authority.py` / Python `evidence`, `campaign`, `contracts` | Isolated Python, source identity and private evidence or authenticated hosted facts | Independent verdict/JSON or failure; evidence, binding, authority and GUI fixture tests cover malformed and successful input. Workflow callers retain artifact and GitHub authority. |
| `run-scheduled-rust-audit.py` / Python | Python on scheduled/manual security runner; checked-out lockfile, pinned scanners, fresh advisory data | Runs scanner subprocesses and writes a bounded summary; `scheduled-rust-audit` tests and `security.yaml` own its policy. |
| `run-windows-vm-tests.ps1`, `windows-vm-guest.ps1`, `windows-vm-acceptance.ps1`, `windows-vm-recovery-acceptance.ps1` / PowerShell modules | PowerShell 7.4+; verified checkout or bundle role closure, host transport or guest session | Launch/control bounded native, UI and recovery work, transfer private evidence, and clean owned resources; registered VM/observer tests cover contracts. Windows runtime acceptance still requires the prepared VM. |
| `run-vm-automated-hosted.ps1` / PowerShell | Hosted Windows validation runner, authenticated candidate metadata and trusted source | Acquires/verifies handoff, invokes campaign and records gate outputs; `run-vm-automated-hosted` tests and `vm-acceptance.yaml` own this path. |
| `prepare-release-cyclonedx.ps1`, `measure-windows-binary.ps1`, `get-git-blob-sha256.ps1`, `validate-release-candidate-metadata.ps1`, `validate-release-handoff.ps1` / PowerShell | PowerShell 7.4+; candidate files, exact Git revision or workflow metadata | Write only requested new output, emit digest/measurement/verdict, or fail; release category tests and release/profile workflows cover their callers. Candidate validation does not promote a release. |
| `resolve-source-matrix-metadata.ps1` / PowerShell | PowerShell 7.4+ in the three manual size/profile matrix jobs; selected profile, checked-out Git source, pinned rustc and runner environment | Validates source SHA/epoch/rustc, rejects existing run/attempt output roots, creates the two roots and appends five `GITHUB_ENV` values; registered `resolve-source-matrix-metadata` and workflow syntax tests exercise the actual CLI. No guest or VM operation. |
| `write-release-files.ps1` / PowerShell | PowerShell 7.4+ in the release candidate checkout; prepared handoff directory, source SHA, run ID/attempt, temporary root | Measures the prepared PE/PDB/archive, writes metrics, handoff and sorted checksums, and removes its temporary measurement; the release workflow validates the result before attestation. The registered release test covers actual CLI output and failure cleanup. |
| `get-release-product-notes.ps1` / PowerShell | PowerShell 7.4+; selected source and optional release tag | Reads the non-empty exact-version prepared section in `DISTRIBUTION.md`; candidate preparation checks it and promotion includes it alongside generated channel, provenance and support disclosures. |
| `capture-local-visual-gallery.sh` → `diagnostics/capture-local-visual-gallery.sh` / Bash | Opt-in Linux/WSL diagnostic from repository root; Wine/Xvfb, cross-build tools, FFmpeg, jq, GNU tools, optional empty absolute output directory | Builds a Windows test executable, captures BMP/PNG and SHA256 manifest, and cleans temporary Wine state. `visual-gallery-diagnostics` tests its wrapper with inert tools; output is diagnostic only. |

Workflow inline code remains owned by each workflow. The remaining bounded
blocks have these owners and review triggers:

| Inline owner | Why it remains inline; extraction trigger |
| --- | --- |
| `binary-size-matrix.yaml`, `profile-benchmark-matrix.yaml`, `profile-planning-matrix.yaml` | Each builds and measures its own experiment profile and emits experiment-specific results. Extract a producer when a second caller needs the same metric contract or the block acquires independently testable parsing or validation. |
| `benchmark-planning.yaml` | Expands that workflow's benchmark parameters and invokes its Cargo loop. Extract if another benchmark stage shares the same input/result contract. |
| `ci.yaml`, `security.yaml` | Route repository test jobs and scheduled audit outcomes from workflow events; the audit parser lives in `run-scheduled-rust-audit.py`. Extract repeated portable parsing, while keeping job permissions, triggers and failure reporting in the workflows. |
| `release.yaml`, `vm-acceptance.yaml`, `promote-release.yaml` | Select trusted source and candidate identities, install pinned tools, attest or publish under workflow authority. The candidate workflow retains its build and information-only summary after the release-file producer extraction. Extract only a cohesive unprivileged calculation with its own fixture contract; keep provenance, secrets, API publication and promotion decisions here. |

Test subprocess callers live under `scripts/tests/`; registered tests may run a
public CLI in temporary fixtures without becoming public commands.

The VM/evidence Python wrappers first re-execute in `-I` before file imports.
They select exactly one checkout or flat-bundle layout, read the expected loader
as one bounded ordinary file without following links, check its SHA-256 pin, and
only then execute the loader bytes. The loader checks the pinned manifest,
authorized role and dependency closure, regular-file/reparse/symlink rules,
bounded reads and read-time identity before importing frozen verified bytes.
An ordinary adjacent import or `PYTHONPATH` replacement would cross this trust
boundary. PowerShell entrypoints likewise choose one layout, check bounded
ordinary manifest and loader bytes against embedded pins, create a temporary
loader module, request the exact role closure, then create a temporary entry
module from verified scriptblocks and remove both modules. The host controller
transfers frozen verified records to the guest. Preserve these paths together
when changing a wrapper, role or bundle; run both bootstrap tests and the
checkout/bundle negative fixtures before any Windows campaign.

The three large review candidates have different ownership. `controller-entry.psm1`
is the sole exported `Invoke-DrWindowsVmController` implementation, called by
`run-windows-vm-tests.ps1`; it composes verified contracts, transport, poll and
rescue definitions while owning session/task state, output inventories and
failure cleanup. Observer, VM and owned-root tests also inspect it directly.
Extraction of independently changing inventory/cleanup policy is plausible,
but requires a new bundle role/pin plus focused failure-order and Windows
cleanup evidence; size alone does not justify a move. `evidence/gui.py` is the
`evidence-gui` role behind `validate-gui-regression-evidence.py`; GUI evidence
tests call its validators. It combines bounded file/JSON loading, source and
transport checks, and distinct text, appearance, performance and icon verdicts.
Scenario-specific verdicts are possible later extraction seams, while common
format decoding already lives in `formats`/`evidence` modules; preserve the
independent verifier and its cumulative bounds. `ui-context-scenarios.ps1` is
the verified UI observer role called by `ui-regression.ps1`; it owns context,
standard, appearance, performance and icon scenario definitions and capture
steps. Its scenario families are plausible seams only when a behavior change
needs independent maintenance and Windows UI evidence; do not split the shared
session/capture state into forwarding files.

The Bash gallery remains an explicit exception. Its public wrapper is called
from the historical Windows acceptance documentation, its implementation runs a
real Wine/Xvfb/FFmpeg pipeline, and its registered test remains in the
`Diagnostics` scope. The prepared Windows VM does not supply the same local Wine
rendering comparison. A Python port would still orchestrate those shell tools
and their signal/cleanup behavior, so this stage retains the tested Bash chain.
Revisit retirement if the local rendering diagnostic has no concrete consumer;
then remove wrapper, implementation and exclusively dependent test/docs in one
review. Revisit a port if a shared Python diagnostic contract demonstrably
replaces the pipeline without changing its output or cleanup. Review embedded
C# whenever a native signature, marshalling, handle lifetime or UI boundary
changes; a separate stage must confirm that no portable policy is stranded in
the CLR strings before changing that boundary. The reviewed `guest-native.ps1`
blocks implement Win32 signatures/structures and handle lifetimes, UI Automation
provider registration, and the WinRT text-scale COM bridge. File-ID formatting
encodes the native identity, and the window-count cap bounds `EnumWindows`;
neither is a separate portable planner or serializer. Keep those ABI and cleanup
operations together. Its PowerShell Windows-root checks enforce the guest's
native filesystem contract; forwarding them to Python would add a guest runtime
without removing that contract.

The three large candidates are retained as cohesive units for this change.
Controller inventory/cleanup is coupled to its remote session and error order;
GUI verdict families share bounded decoding/source checks while remaining
independent from their producers; UI scenarios share one observer session and
capture state. Existing `formats` and `vm.connection` modules already own shared
portable decoding and connection mechanics. Revisit a split when a specific
scenario or cleanup policy needs independent maintenance, then update the
authenticated role closure and run its focused fixtures plus any affected
Windows cleanup/UI evidence.

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
producer verdicts with the independent verifier. Both consumers cap all PNG
chunks, including zero-length ancillary chunks, at 4096 before header/CRC work.
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

VM host tools use `/usr/bin/pwsh` and `/usr/bin/wslpath` by default and require
trusted `/usr/bin/ssh` for transport. For another
installed location, set `DARKRENAMER_PWSH_PATH` or `DARKRENAMER_WSLPATH_PATH` to
its absolute executable path. The resolver checks every parent, symlink and
target for root/current-user ownership and rejects group/other writable paths
before any version probe. It never falls back to ambient `PATH`. If an installed
tool is rejected, inspect its ownership and permissions and select a protected
installation; the tooling does not change host ACLs or SSH settings.

The SSH PowerShell child searches only `/usr/bin:/bin` and preserves required
`HOME`, `SSH_AUTH_SOCK` and WSL interop inputs. Unneeded private environment
values are not inherited. The current user and administrator remain trusted;
pathname checks are not a general race-free execution guarantee against a
fully compromised host.

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

### ListView refresh stage diagnostic

On the prepared VM, run the fixed native refresh diagnostic from a clean,
committed checkout with a new private output directory:

```bash
python3 -I scripts/test-windows-vm.py \
  --ssh-host configured-vm-alias \
  --desktop-helper 'C:\absolute\private\desktop-session.ps1' \
  --profile-refresh-stages \
  --output /absolute/private/new-refresh-stage-attempt
```

The helper profile must bind the SSH alias to the prepared VM. Do not pass
`--expected-vm-id` on this source-built SSH core path; that option belongs to
the `--vm-name` PowerShell Direct path. The selector fixes a managed 1366×768,
96-DPI RDP desktop, the v2 owned-resource cleanup profile, a 600-second test
and suite limit per pass, and a 32 MiB aggregate output limit per pass. It
builds one optimized app-library test binary and an uninstrumented production
EXE once, then runs exactly the ignored
`windows::list_view::native_tests::profile_refresh_stages` test with those same
bytes in hidden-visible and visible-hidden order. It stops on the first failed
pass and retains the output root, `plan.json`, `attempts.json`, and each
attempt's evidence. A passing diagnostic requires both passes and verified
guest cleanup.

Each pass emits stage timings and counts for ordinary 100/1,000/10,000-row
refreshes, an unchanged 10,000-row refresh, proposal edits/resets, and long
paths with auxiliary columns hidden and visible. The native test checks row
counts, representative text in all eight ListView columns even when auxiliary
columns are hidden, icons, and selection preservation. The current streaming
test emits `refresh-stages-icon-async-streaming-test-build` schema 3 with
`icon_worker_attached=false`: this is a detached UI staging measurement. Its
`row_values_inclusive_ns` contains `timestamps_nested_ns` and
`ui_shell_nested_ns`; `row_values_exclusive_ns` excludes both. The UI Shell
timings and call count, plus icon submissions and drains, must be zero.
`render_icon_cache_hits` and `render_icon_cache_misses` describe staging cache
lookups, not worker Shell calls. Schema 3 adds separate peaks for one-row normal
staging and full-vector fallback staging, retained rendered-vector capacity
bytes and growth events, and repeated nonzero FILETIME inputs. For the fixed
eligible workloads, normal staging owns at most one transient row and fallback
staging is zero. The repeated-input counter resets on each refresh and counts
adjacent identical nonzero values; it is a test-only input count, not evidence
of date caching. Vector capacity bytes describe the backing allocation, not
allocator or process peak memory. The native apply/rebuild clock excludes row
formatting. Historical `refresh-stages-icon-async-test-build` schema 2 retains
its original detached icon meaning, and `refresh-stages-test-build` schema 1
retains its synchronous Shell/cache meaning. The validator keeps all three
schemas separate and rejects mixed records. Do not add inclusive and
nested times. `scenario_envelope_ns` may include fixture changes and assertions
outside the stage clocks; it is not a pure refresh duration.
`logical_staged_payload_bytes_peak` counts UTF-16
payloads staged by the refresh path; it is not process memory or an allocator
measurement. The test-only clocks and counters do not measure the production
EXE's response time.

The synthetic metadata snapshots exclude import read/decode, admission,
delivery, and observer polling. This detached native test does not measure
worker Shell latency, icon settlement, or the production EXE's async path.
For sampled production timing and resource use, run the separate unchanged
[fixed performance sample](#fixed-performance-sample). Neither diagnostic is a
release acceptance verdict.

### Icon worker native functional tests

After the icon worker's fixed native tests are present in a clean source commit,
run each build profile on the prepared VM with a separate private output root:

```bash
python3 -I scripts/test-windows-vm.py --ssh-host configured-vm-alias \
  --focused-icon-tests --native-test-profile debug \
  --output /absolute/private/new-icon-debug-attempt
python3 -I scripts/test-windows-vm.py --ssh-host configured-vm-alias \
  --focused-icon-tests --native-test-profile release \
  --output /absolute/private/new-icon-release-attempt
```

The selector requires source-built core mode, the prepared 1366×768 96-DPI
managed RDP desktop, and the existing v2 owned-resource cleanup profile. It
builds one app-library test executable for the selected profile and one
production executable, then runs the four fixed non-ignored `icon_worker_*`
cases in separate owned processes and Jobs using the same frozen executable
bytes. The run has one 600-second suite deadline and the existing aggregate
output bound. Each case must report its exact name and one executed test;
execution stops at the first failed case and retains its actual libtest counts.
For a single diagnostic case, add `--focused-icon-case` with one of the four
fixed case suffixes reported by `--help`. This runs exactly one process. The
regular native suite and the separate refresh-stage diagnostic retain their
existing selections. These test-build observations do not measure production
icon-settlement or replace the uninstrumented performance sample.

### Refresh native functional tests

Run the four fixed refresh cases from one clean source commit on the prepared VM,
with a new private output directory for each build profile:

```bash
python3 -I scripts/test-windows-vm.py --ssh-host configured-vm-alias \
  --focused-refresh-tests --native-test-profile debug \
  --output /absolute/private/new-refresh-debug-attempt
python3 -I scripts/test-windows-vm.py --ssh-host configured-vm-alias \
  --focused-refresh-tests --native-test-profile release \
  --output /absolute/private/new-refresh-release-attempt
```

This selector requires source-built core mode, the prepared 1366×768 96-DPI
managed RDP desktop, and the v2 owned-resource cleanup profile. It builds one
app-library test binary for the selected profile and one production executable,
then runs `native_rows_and_proposals`, `native_fallback_and_apply_lock`,
`native_dates_follow_locale_and_timezone`, and `native_viewport_focus_and_close`
as exact, non-ignored tests in separate owned processes and Jobs. The frozen
binary is reused across all four cases. Each case must report its exact name
and one executed test. The shared suite deadline is 600 seconds, with a 32 MiB
aggregate output bound; execution stops on the first failed case and retains
the actual libtest counts and v2 cleanup evidence. Add `--focused-refresh-case`
with one of those four suffixes for one diagnostic process. These functional
tests do not replace the ignored refresh-stage timing diagnostic or the
separate production performance sample.

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

The supported packaging route is Linux or WSL on a local Linux filesystem with
enforced POSIX permissions. Create a fresh parent outside the checkout first;
keep the output directory and ZIP as siblings beneath it. For example, replace
the placeholder inputs with the frozen candidate and configured connection:

```bash
task_evidence_parent="$(mktemp -d "$HOME/darkrenamer-evidence.XXXXXXXX")"
python3 -I scripts/run-vm-automated-campaign.py \
  --connection-profile /path/to/private/connection-profile.json \
  --backend-root /path/to/source-bound/backend-bundle \
  --candidate-handoff-root /path/to/immutable/candidate-handoff \
  --candidate-source-root /path/to/clean/same-sha/checkout \
  --candidate-run-metadata /path/to/candidate-run.json \
  --candidate-artifact-metadata /path/to/candidate-artifact.json \
  --candidate-source-sha '<40-character-source-sha>' \
  --candidate-workflow-run '<candidate-run-id>' \
  --candidate-run-attempt '<candidate-run-attempt>' \
  --candidate-artifact-id '<candidate-artifact-id>' \
  --candidate-executable-sha256 '<64-character-executable-sha256>' \
  --output-root "$task_evidence_parent/campaign" \
  --archive "$task_evidence_parent/campaign.zip"
```

Use this example only when `$HOME` is on the supported filesystem and outside
the checkout; otherwise select an equivalent local Linux storage location.
The runner checks both parents before creating output or accessing the VM, and
the packager repeats the archive-parent check. It opens each parent without
following a direct symlink and requires an ordinary directory owned by the
effective user with exactly `0700` permissions. Unsafe parents are refused;
their permissions, ownership and contents are not repaired. Required POSIX
directory-descriptor and no-follow operations must be available.

The packager retains the validated parent descriptor for relative creation,
validation, publication and cleanup, and rechecks parent identity and privacy
before publication or deletion. Keep the parent private through packaging and
upload. The operator must ensure that the filesystem actually enforces this
boundary; capability and mode checks do not certify mount behavior or ACLs.
Native Windows packaging and Windows-backed WSL destinations are unsupported.
Windows-execution source and candidate mirrors are separate from this private
POSIX raw-evidence storage. Moving or copying raw evidence requires equivalent
protection at its destination.
The packager exclusively creates its temporary archive with owner-only (`0600`)
permissions before writing any raw observations, and retains that mode when
publishing the final archive without replacement. No later `chmod` is needed to
establish initial file privacy. Cleanup authenticates each name against the
created object while retaining its original descriptor. Replaced names,
changed parents, unknown creation identity or cleanup errors cause failure and
leave unverified objects untouched; no successful receipt is returned for
uncertain publication or cleanup. Diagnostics remain private local evidence.
This protects against unrelated unprivileged accounts, assuming the parent
remains private. It does not protect against root, a compromised same-user
process or a compromised filesystem, and pathname checking followed by unlink
is not a universal atomic conditional-delete operation. It makes no durability
or secure-deletion claim.

These prospective protections do not establish creation-time privacy for
historical archives, including v0.1.5's archive whose permissions were restricted
only after creation. v0.1.6 already used exclusive `0600` creation and no-replace
publication; that historical producer did not enforce the private parent or
authenticate every cleanup name. The new checks do not retroactively prove
those boundaries for v0.1.6 evidence.

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

### Fixed GUI cleanup profiles

For future four-cell GUI validation under the existing v2 owned-resource
contract, select that profile explicitly from a clean, committed checkout:

```bash
python3 -I scripts/run-gui-regression.py \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-fixed-gui-v2-attempt
```

The four geometry, appearance, text-scale and scenario choices keep their
existing limits. V2 uses distinct `-owned-v2` run IDs and binds the selected
source's profile blob, typed revision, staged artifact and digest through the
producer, controller, raw transport and independent verifier. Validation requires
all candidate lifetimes and their closed Jobs, complete owned-resource and
required-environment observations, and successful settings restoration. Ambient
process residency alone does not change the existing v2 contract.

Omitting the selector retains historical v1 behavior and its original run IDs;
explicit v1 remains available. Preserved v1 failures cannot be reclassified as
v2 success. Fixed GUI diagnostics do not replace the complete source-bound
release campaign or human visual acceptance.

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
existing `vm-automated-v1-win11-ntfs` cleanup profile by default. An explicit
`--acceptance-profile-id vm-automated-v2-owned-resources` selects the existing
V2 owned-resource cleanup contract for this diagnostic only. The launcher
freezes the unchanged `config/vm-automated-v2.json` bytes and digest in each
input, binds the controller arguments to them, and independently verifies the
complete V2 cleanup inventory and the observer Job and process lifetimes.
For this diagnostic, use the selector with `--diagnostic appearance-pair`.
The separate fixed-GUI selector above does not change either profile definition
or the release matrix.
V2 permits ambient process deltas only under its established ownership and
required-environment checks. Preserved V1 failures retain their original verdict.
Selecting V2 cleanup here does not establish complete V2 release acceptance.

The diagnostic retains 69 original guest desktop PNGs. Eight main states
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
The fixture first resets the native horizontal position to its minimum, then
uses the same final pixel delta in every phase and allows painting to settle.
The native XOR focus rectangle cannot be scrolled safely through differing
small deltas. The strict original Light endpoint comparison remains unchanged.
Normalized scene composition establishes raster conformance at a controlled
viewport; it does not prove that a theme command preserved the preceding
viewport. The v3 diagnostic separately establishes non-minimum horizontal and
vertical positions once in the custom-width overflow fixture. It records
read-only native snapshots immediately before and after each Light → Dark →
Light transition, before any proposal exposure, selection, focus repair or
scroll normalization. Committed native positions/ranges and viewport anchors,
row values, selected identities, column settings and geometry must remain
unchanged. Transient scroll tracking metadata is retained separately. Bounded
settlement only observes state; it never repairs a failed transition. Original
partial snapshots remain in the observer output on failure. Matching later
normalized captures cannot turn a failed preservation check into a pass.

A separate clean-start session uses the same executable and display configuration
with its own isolated `LOCALAPPDATA`. The observer verifies `ui-columns-v1` is
absent before launch and never injects widths or changes header settings. One
unchanged multilingual row is compared through Light → Dark → Light using
actual automatic allocation, with persisted columns distinguished from the
runtime-only status column. Three original `appearance-default-columns-*` PNGs
and native state support the default-layout check; the oversized persisted-width
scenes remain separate. Normal preference creation after startup is allowed.
Both sessions retain the existing owned-process and settings cleanup contract.

The v3 observation scope distinguishes these two guarantees from the earlier
v2 normalized-state evidence. Historical results remain bound to their original
source and verifier; they do not establish unnormalized preservation or clean
startup defaults. The independent result reports transition preservation,
normalized raster conformance and clean-default allocation separately.

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

For the fixed five-configuration check, use the same command with
`--configuration-set focused` and omit the desktop arguments. The runner builds
one bundle and executes 1920×1080 at 96, 144 and 192 DPI, Text150 at 96 DPI,
and Forced Colors at 96 DPI sequentially. The independent verifier compares the
source tree, bundle manifest and all staged artifact hashes across the five runs.
Text150 compares the same original Korean prompt glyphs with the baseline in
both dimensions, with unchanged font-family inputs. The label is observed on its
bound STATIC using bounded `WM_GETTEXT`; no foreign font pointer is read.

The Forced Colors run adds three System captures after its 69 ordinary scenes.
It records System foreground resolution before activation, native fallback with
selected/unselected semantic text during activation, and exact restoration of
System state and client pixels. Source/script-bound restoration receipts precede
setting mutations. Producer `finally` and existing controller terminal/timeout
rescue paths restore the original settings, and collected receipts must verify
restoration. Normal OS Light/Dark setting transitions are not exercised.

The independent verifier checks source/EXE/environment bindings, exact capture
inventory, state invariance, proposed-name semantic pixels without current-name
color leakage, selection transitions, actual cursor targets, one-pixel outlines,
default cues, quiet dividers, text ink, pressed displacement and focus perimeter.
Dark native thumb/track/intersection palettes and the strict original Light client
endpoint comparisons are conformance gates. A passing verdict applies to the
declared scenes and configurations; design approval remains separate. This
opt-in diagnostic does not complete the four fixed GUI regression runs or
release acceptance.

### Fixed performance sample

Run one source-bound performance sample on a clean committed checkout with the
prepared 1366×768, 96-DPI VM desktop:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic performance-sample \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-performance-sample-attempt
```

Freeze the product and harness commits, executable hashes, toolchain/profile,
fixture contents/order, display, initial preferences and cache policy before a
comparison. Start with two complete observations per product in a declared
balanced order, such as baseline/candidate/candidate/baseline. Each attempt has
a new output root and a 600-second observer and 32 MiB output limit. To keep
both observations bound to the same executable bytes, first build with
`scripts/test-windows-vm.py --prepare-only --output /absolute/private/native-bundle`.
Read and freeze `application.sha256` from its `bundle.json`, then pass
`--prepared-bundle-root /absolute/private/native-bundle` and
`--expected-prepared-application-sha256` with that digest to each performance
invocation. Prepared reuse is restricted to declared performance, focused-clear,
and icon-settlement diagnostics; the runner verifies
the clean source, executable, test binaries and trusted native tooling closure
before contacting the VM. Each attempt retains its own authenticated inputs and
prepared-bundle provenance. The fixed workload observes 30 seconds of empty idle,
100/1,000/10,000 ordinary rows, 1,000 long paths with auxiliary columns hidden
and visible, 300 extension classes with recurring `.txt`, one-row and full-list
preview/reset with five representative rows including the last row, then three
1,000-row add/edit/reset/remove cycles. `ordinary-10000` retains its historical
meaning: the sum of four 2,250-row additions to an existing 1,000-row list.
Import elapsed time begins at dialog Open invocation and ends at observed row
count; it includes completion handoff, rendering and observer polling. It does
not isolate file I/O or establish complete command readiness. Full-preview time
includes representative row observation; cycle time includes import, edit,
reset and removal. Readiness and representative values remain separate evidence.
Use `--performance-column-order hidden-visible` or `visible-hidden` to declare
and counterbalance long-path column order. Shared OS/Shell cache effects remain
possible even with fresh application processes and private preferences.
Import lists stay
below the existing 2 MiB limit. The observer samples the exact owned product
PID and HWND every 200 ms during import and refresh, recording CPU, private and
working-set bytes, threads, handles, GDI objects, and bounded `WM_NULL` probes.
The v2 timing scope separates probe duration from resource collection and
distinguishes success, identified timeout and other/unknown failure using the
native last-error contract. Per-phase sample counts and gaps describe coverage;
a 50-ms timeout does not measure the complete stall, and 200-ms sampling can
miss peaks. Startup records launch-request-to-declared-ready time and monotonic
bounds around native process creation; the ready criterion is a bound main
window, an empty list and an enabled import command. Post-operation resources
use the fixed 400-ms settling interval. Wakeups remain `not_run` because this
observer has no supported per-process counter. The independent validator checks source and executable hashes, the
fixed workload and sample sequence, visible column values, unchanged fixture
bytes, journal absence, normal process close, and cleanup. Changed semantics use
a distinct run/scope identity; original v1 receipts retain their original source
and verifier. For historical comparisons, commit harness-only backports and
prove that product/build inputs are unchanged; record both original and derived
commits rather than presenting a modified checkout as the original source.
Retain every failed attempt. Additional focused observations require a stated
hypothesis and fixed count; two observations do not establish significance or
tail latency. These samples do not
complete the four-cell GUI regression, appearance diagnostic, release campaign,
or physical-media acceptance.

### Focused first-10k-clear diagnostic

Use `focused-10k-clear` only for a separately authorized, single observation of
the first clear after the ordinary 10,000-row full preview/reset. It retains
the original source-built product EXE and original bundle manifest unchanged,
while separately binding the corrected tooling to the current clean checkout.
Pin both origins before VM contact:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic focused-10k-clear \
  --preserved-product-bundle-root /tmp/issue32-bootstrap-baseline-prepared-8248c73 \
  --expected-original-bundle-sha256 23f42a2c2af9e7a9417e275e10b9415be46dc05a0ecf610527a89e632ec7f38e \
  --expected-product-source-sha 8248c73859e3a3ff0e524fd9448acfe965fa3f68 \
  --expected-tooling-source-sha <current-clean-tooling-source-sha> \
  --expected-prepared-application-sha256 06c5511e042714f5a343e541856f2dbdc3850d5d60eeb62c3c36c2dacfef2f0f \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-focused-clear-attempt
```

The distinct `focused-10k-clear-v1-1366x768-96-text100` run repeats the original
30-second idle, 100/1,000/10,000 ordinary rows, four 2,250-row additions,
single-row preview/reset, and five-row full preview/reset. It records the bound
product PID and HWND, pre-clear rows, native command result and last-error class,
post-clear rows, sampler coverage, exact normal exit, and the existing strict
V1 guest cleanup. It stops after the first successful clear and does not run
long-path, extension, or cycle phases. The 5-second native command timeout,
600-second observer limit, one-PNG/32 MiB collection cap, and original fixture
and disk/journal checks still apply. Failed attempts retain their original raw
failure and partial observations; later cleanup cannot convert them to success.
This receipt is an observation, not a full performance comparison or release
acceptance. The original failed performance receipt stays failed, and the
focused result cannot supply normal A/B/B/A medians.

### Icon settlement diagnostic

After the native icon worker passes its functional checks, run the separate
candidate-only production-EXE diagnostic on the prepared 1366×768, 96-DPI VM.
Prepare a source-built bundle and pin its `application.sha256` as described in
[the fixed performance sample](#fixed-performance-sample):

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic icon-settlement \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --prepared-bundle-root /absolute/private/native-bundle \
  --expected-prepared-application-sha256 <frozen-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-icon-settlement-attempt
```

The `icon-settlement-v1-1366x768-96-text100` receipt uses its own
`async-status-v1` endpoint method and raw scope. It imports 1,000 ordinary
`.txt` rows, clears them, then imports 1,000 rows interleaving 299 unique
extensions with recurring `.txt` (300 classes total). It records the existing
Open-to-UIA-row-count data-ready endpoint separately from the later observed
icon-settled endpoint. A pointer-free, versioned main-window scalar query is
sampled every 100 ms within the existing 600-second observer limit. Settlement
requires an attached system image list, zero unresolved rows, exhausted demand,
empty queued/in-flight/completion/reconciliation state and the same full
generation in consecutive stable snapshots. Both pre-close snapshots must also
show a nonzero worker session, `unavailable_or_retiring=false`, and
`worker_joined=false`. A missing query, failed bootstrap, retired or unavailable
worker, changed session or deadline produces a failed attempt, not a baseline fallback.
Terminal negative Shell results may legitimately remain no-image; settlement
means no unresolved demand, not a visible glyph on every row.
The verifier binds the source, prepared EXE, process ID and start time, exact
normal exit, and the existing v2 owned Job and observer cleanup. An ordinary
fast close may retire the HWND before an external joined-state sample; such a
receipt labels worker join as a source-contract inference. Controlled native
close tests provide the separate direct join proof.

For the pre-worker synchronous source, use the same `icon-settlement`
diagnostic, V2 owned-resource profile, prepared-bundle pin, display, and two
fresh fixture phases, but select its separate baseline endpoint explicitly:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic icon-settlement \
  --icon-endpoint-method synchronous-row-count-upper-bound-v1 \
  --baseline-product-source-sha b152761010b16ef74e2a3765241a253778b88e0b \
  --expected-run-source-sha <frozen-tooling-only-commit-sha> \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --prepared-bundle-root /absolute/private/native-baseline-bundle \
  --expected-prepared-application-sha256 <frozen-baseline-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-icon-baseline-attempt
```

The baseline has run ID
`icon-settlement-sync-upper-bound-v1-1366x768-96-text100` and a distinct raw
scope. Its `synchronous_lookup_completion_upper_bound_ms` equals the existing
Open-to-UIA-row-count `data_ready_ms`. The pre-worker source finishes synchronous
Shell icon lookup before adding each row, so RowCount is a source-derived upper
bound for lookup completion. It does not observe actual icon visibility,
workers, queues, or joins and emits no status snapshots or fabricated zero
counters. The shared plan's 100-ms status poll applies only to the async method.
The baseline method is never inferred when the async status query is
missing. The command requires the original product reference and the exact
clean tooling-only run SHA; the prepared EXE hash and source are pinned before
VM execution. A separate source audit must establish that the tooling-only
checkout's product Rust, Cargo and toolchain blobs match the original product
reference; the manifest's asserted reference does not perform that audit.
Compare the baseline upper bound and candidate observed endpoint descriptively,
recording their different methods and any censored attempts. These samples do
not establish a causal or statistical speed claim.

Keep both endpoint methods separate from the unchanged A/B/B/A
`performance-sample-v2` runs; the async settlement wait changes later workload and cache
conditions. Neither diagnostic is a release acceptance verdict.

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

Candidate tool installation uses `config/release-tool-integrity.json` and
`scripts/install-verified-release-tools.ps1`. Update the canonical version owner
and review the official archive URL, full-byte SHA-256 and layout together.
The release-tool integrity fixtures cover wrong bytes before execution, stale
pins, unsupported assets and corrupt retained inputs. Complete the registered
release category and a non-publishing hosted candidate after pin changes;
fixture passes alone do not establish Windows installation or signing success.
