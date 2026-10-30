# Development

DarkReNamer pins its Rust toolchain in `rust-toolchain.toml`. Run commands from
the repository root and use the committed lockfile. The project supports three
different validation environments; none substitutes for the others.

Start with the [Windows gate](#native-windows-development) or
[Linux/WSL gate](#portable-checks-on-linux-or-wsl), then use
[focused tooling selections](#tooling-tests) during edits. The
[routine workflow](#routine-maintenance-workflow) distinguishes required gates
from optional diagnostics. [VM procedures](#native-tests-in-a-local-hyper-v-vm)
and [release tooling](#release-tooling) cover their separate handoffs.

## Production Rust and Win32 code

These are authoring defaults; the [safety model](SAFETY.md),
[preview resource boundary](SAFETY.md#preview-resource-boundary), and
[native boundary policy](SAFETY.md#unsafe-boundary-policy) are mandatory contracts.

- Use the pinned rustfmt and existing editor settings. Keep explicit grouped
  imports with matching visibility and `cfg`, and import only the test owner's
  dependencies. Preserve public compatibility paths and target reachability.
  Avoid production glob imports, arbitrary file/function-size quotas, and
  aesthetic field reordering, especially where destruction order matters.
- Prefer concrete types, clear units, early rejection, and explicit state
  transitions. Use enums/newtypes when they prevent a real mistake; do not wrap
  every boolean/integer or build a trait/factory layer for each helper. Borrow
  for synchronous inspection and transfer ownership for longer-lived work;
  retain justified snapshots, `Arc`, and resource-specific guards.
- Reuse immutable metadata rather than repeatedly collecting and sorting it,
  as the command catalog's derived rail view does. Use small local arrays for
  structural bounds, as the prompt's three fixed and three optional sections
  do. Preserve checked arithmetic, aggregate budgets, fallible preparation,
  and atomic commit. New queues/caches must bound queued, in-flight, and
  undrained completed work, with explicit saturation, invalidation,
  cancellation, and retirement. Terminal results are not replaceable progress.
- Retain precise `SAFETY` reasoning, API-specific return/error handling,
  callback ABI, thread/apartment affinity, ownership, and reentrancy contracts.
  Preserve prepare/release/native-call/reacquire/revalidate where applicable;
  do not replace every synchronous message or merge distinct destructors into
  a universal handle wrapper.
- Keep exact UTF-16 operational values separate from lossy display text,
  typed mutation certainty and explicit journal durability, and proposal
  editing separate from filesystem mutation. Extend the existing command
  catalog and preserve focus, accessibility, and Forced Colors behavior.
  Distinguish DIP layout from physical-pixel painting; keep blocking I/O and
  unbounded work out of UI handlers.
- Retain existing lint and release-profile policy. Do not enable all Clippy
  `pedantic`/`restriction` lints, nightly formatting options, or another style
  checker. Complete the [maintenance gates](#routine-maintenance-workflow) and
  applicable [native validation](#native-tests-in-a-local-hyper-v-vm).
  Binary-size claims require comparable builds; memory/speed claims require
  comparable [performance samples](#fixed-performance-sample). Reviewed
  allocation removal alone does not establish an application-level speedup.

### Preference read authority

Column, appearance and language files have independent write authority. A successful read
or a genuinely absent file permits that file's writer; an initial read error
uses safe display defaults but starts no writer for that file for the session.
Column and appearance edits and resets still affect the current UI, but are not
persisted, and the UI reports that limitation. An initial language-file read
failure blocks new language choices for that session. There is no in-session
retry or reset that restores write authority: restart retries the read, and
unpersisted column/appearance edits are discarded. The other files remain
independently writable. Both normal close
and message-loop failure retire all writers that were started. This preserves
unread bytes across every save path while keeping existing bounded coalescing,
latest final snapshots, atomic replacement and failure reporting for authorized
writers.

### Embedded UI language maintenance

`crates/darknamer-app/src/i18n.rs` owns the supported languages, immutable startup
selection and typed `catalog!` representation. The four catalog owners under
`src/i18n/` cover command metadata, shared presentation, native controls and
runtime/recovery messages. Translations are compiled into the single EXE; there
are no language downloads or runtime text parsers. Typed Rust catalogs keep the
small fixed language set and format arguments checked without a serialization
library or external language-pack lifecycle.

Add complete Korean/English/Japanese messages in that order. Use typed static
keys for labels and a named function for complete formatted messages. Each
format is compiled with the same named arguments, so missing/extra parameters
are build errors. Keep counts grammatically valid for zero, one and multiple
items; use a count label or an explicit grammatical branch where needed.
Translate safety intent, including all-list Apply scope, no replacement,
proposal-only reset and retained recovery locks. Never translate path inputs,
rewrite UTF-16 values or substitute rendered diagnostics into filesystem calls.
Keep diagnostic kinds, native codes and technical/OS-owned exceptions defined
in the [user guide](docs/USER-GUIDE.md#language).

Native rendering uses `CommandUiSpec.localized_*` and
`ColumnSpec.localized_label()`; the immutable Korean compatibility label fields
are not active UI text. Startup resolves the language before app-owned fatal or
recovery guidance. `windows/language.rs` uses the Windows UI-language API without
changing regional locales. The independent versioned preference record reuses
safe persistence; a successful initial read, uncertain legacy migration, pending
write and acknowledged durable choice are distinct states. Menu selection tracks
acknowledged writes, while running text stays in the startup language.

Run focused i18n, confirmation, preview and preference tests before the full
gate. Test overrides are thread-local and restore the caller, so concurrent
language tests cannot change one another. Native/VM validation must exercise
actual translated prompts, full accessible names, settings/restart and file
outcomes; catalog or geometry tests alone do not establish visible layout or
Windows execution. Keep tested/landed source, EXE identity, footprint comparison
conditions, inspected captures and remaining release-only scope in the external
completion record.

### Foreground worker ownership

`AppState` owns four optional foreground workers: admission, import, planning,
and apply. They are intended to run one at a time. File-dialog and drop
admission use their session and `drop_locked` gates; import starts only after
the file-dialog session passes its revision and lock checks; `apply_changes`
uses `apply_locked` before planning, and the confirmed plan passes the prompt,
revision, fingerprint, and lock checks before apply. The worker-start helpers
are not a second, general admission API: callers must preserve these gates.
`mutation_locked` also covers modal transitions and close, while recovery and
journal state independently prohibit apply. See `windows.rs` (`AppState`,
`apply_locked`), `windows/command_dispatch.rs` (file-dialog sessions),
`windows/drag_drop.rs` (drop gate), and `windows/worker.rs` (start paths).

Each worker retains its cancellation token, bounded terminal-result receiver,
and thread handle in its own `AppState` field. Cancel requests are cooperative;
an acknowledged request is not retirement. Completion is polled or posted to
the UI thread, which waits for the thread's terminal state, takes its worker,
joins it, and consumes its terminal result once before accepting a new mutable
operation. Import and admission reject stale session or model revisions;
planning rechecks the revision and confirmation state; apply revalidates the
confirmed immutable plan before filesystem mutation and retains journal
evidence for uncertain outcomes. Failure and missing-result paths retire the
worker too. `request_window_close` requests cancellation and
`try_finish_window_close` / `prepare_window_close` require every foreground
field to be empty before destruction. On message-loop failure, the separate
shutdown path joins owned workers; an import provider that cannot retire
forces process abort rather than releasing its runtime lock while it runs.

Native callbacks may reenter during synchronous messages. The current
prepare/release/native-call/reacquire/revalidate pattern keeps an `AppState`
lease out of those calls; a copied session or revision is checked after return.
Win32 [`SendMessage`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessage)
is synchronous, and a receiving thread can process incoming nonqueued messages
while waiting on a cross-thread send. Worker fields remain owned until join;
cancellation alone cannot clear them. Icon work
has separate retirement and join state. Appearance and column preference
writers have their own bounded persistence, failure reporting, and shutdown;
window close waits for them independently of the foreground worker fields.

The four fields admit more *representable* combinations than the intended
single foreground operation. `worker_activity` and `active_worker_kind` project
them for controls; the latter returns no kind for both idle and multiple active
flags, but its boolean test does not establish a reachable overlap. Existing
native tests cover stale import retirement, admission cancellation, and close
while icon work is active (`windows/application.rs`, `windows/list_view.rs`);
they do not prove a simultaneous foreground worker state is reachable. A shared
projection of the repeated field checks would shorten some lock and close
predicates, yet would leave the distinct cancellation, result, join, and
failure transitions at their current owners. A Rust
[`enum`](https://doc.rust-lang.org/book/ch06-01-defining-an-enum.html) could encode one active
variant in Rust's type system, but moving these lifetimes through callback,
prompt, and shutdown paths would add broad transitions and drop-order review.
The current procedural gates and worker-specific retirement remain the smaller
supported design until a concrete overlap or missed transition is found.

## Native Windows development

Install Git, PowerShell 7.4 or newer, Python 3.11 or newer, and rustup. The tooling
runner invokes `python` on Windows, so that command must resolve to a usable
Python installation. Check its path and version in PowerShell:

```powershell
Get-Command python -CommandType Application | Select-Object -First 1 -ExpandProperty Source
python --version
```

Opening this repository causes rustup to select the pinned compiler, `rustfmt`,
`clippy`, and the Windows MSVC target. A Visual Studio Build Tools installation
with the current Windows SDK is also required. Prepared-VM validation has
[additional host requirements](#native-tests-in-a-local-hyper-v-vm).

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

Install Git, PowerShell 7.4 or newer, and Python 3.11 or newer in addition to the
pinned Rust toolchain. The tooling runner invokes `python3` on Linux/WSL. Check
its path and version:

```bash
command -v python3
python3 --version
```

The Windows-target check also needs the LLVM resource compiler described in
[Linux cross-build](#linux-cross-build); set `RC` to its installed path when
using a different location. Prepared-VM validation has
[additional host requirements](#native-tests-in-a-local-hyper-v-vm). The portable
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
4. Run standalone GUI or optimization diagnostics
   only for a concrete investigation, using their existing bounded utilities
   and opt-in scopes. Ambient OS activity alone does not mandate diagnosis or
   create a release requirement. Preserve failures and inspect their evidence
   before a corrective change justifies another workload.

### Documentation-only CI routing

CI may use a shorter path only when every change from the protected `master`
commit to the checked-out PR or merge-queue tree is a modification of an
existing ordinary file in this reviewed list: `README.ko.md`, `README.ja.md`,
`docs/USER-GUIDE.md`, `docs/USER-GUIDE.ko.md`, or
`docs/history/WINDOWS-ACCEPTANCE.md`. These files are linked from other
documents and checked by the tracked-document inventory. VM evidence tooling
also hashes tracked blobs for source binding; no current build, runtime, or
release tool consumes their content as an input. Reassess their consumers before
expanding the list or adding such a reader. `README.md`, `DEVELOPMENT.md`,
`DISTRIBUTION.md`, safety and security policy, the document inventory, and
uncertain documents stay on the full path.

The classifier executes the policy from the protected base. It compares the
complete trees, including all commits in a PR or merge group; a push compares
its prior protected commit with the checked-out commit. Additions, deletions,
renames, mode/type changes, missing history or policy, malformed results, and
manual runs select the full path. The implementation PR itself takes that full
path because its workflow and classifier change.

On the documentation path, `pr-gate/quality` still checks the Rust-only source
and tracked-document inventory. `pr-gate/security` still validates its pinned
tools and checks fresh advisories and dependency policy. `pr-gate/unit` and
`pr-gate/windows` report successful steps that state the omitted tests are not
required for this change; quality also states why Rust, Clippy, and tooling
were omitted. A green no-op is not evidence that those tests ran. If
classification fails, all three dependent gates run their original full
commands. A canceled workflow is not a completed validation result. The
separate scheduled security workflow is unaffected.

The Rust dependency-audit job in `.github/workflows/security.yaml` runs on its
weekly schedule and by manual dispatch, including when source is unchanged.
CI retains the pull-request, push, and merge-group dependency gate. The
scheduled job caches pinned scanner binaries only; each run refreshes advisory
data and checks the selected `Cargo.lock` and dependency policy anew. A failed
refresh or scan is a failed check, not a clean result.

The scheduled/manual adapter also rejects registry-index failures reported at
exit zero, including cargo-deny's warning-level index diagnostics and the pinned
cargo-audit registry-error messages outside its JSON report. A clean full
cargo-deny check requires exactly one complete four-check summary with valid
counters; empty, partial, duplicate, or malformed output is incomplete. Ordinary
permitted policy warnings remain nonfatal. Classified failures retain scanner
diagnostics in the job log without copying raw output into the Markdown summary.

### Why both Rust dependency scanners remain

The [completed #94 scanner investigation](https://github.com/PiesP/DarkReNamer/issues/94#issuecomment-6140820886)
retains both cargo-audit and cargo-deny. Its complete controls and failure
receipts remain in that closeout and in the
[immutable investigation-era source](https://github.com/PiesP/DarkReNamer/blob/599947b878da65ae0a750e8582e6f96f107ff195/DEVELOPMENT.md#L71).
The scanner entries in `config/release-tool-integrity.json` own selected versions
and reviewed source or Windows artifact identities. `cargo-audit` 0.22.2 is
built from its SHA-256-pinned published crate with
`config/cargo-audit-0.22.2-patched.lock`; that lock updates the affected
`rustls`, `rustls-webpki`, and active `h2` closure while preserving the reviewed CLI and
report version. `scripts/build-patched-cargo-audit.py` verifies both inputs
before extraction or execution and uses `cargo build --locked` with isolated
Cargo state. CI, the scheduled audit, and the Windows candidate installer use
that same builder. CI and the scheduled audit read scanner selections through
`run-scheduled-rust-audit.py --emit-pins`; workflows still own cache restoration,
the pinned `cargo-deny` install, permissions and setup failure reporting. The
same runner checks exact executable versions, while the Windows installer
validates reviewed source and archive bytes independently of workflow syntax.
Audit inspected the complete, unpruned lockfile;
deny inspected a selected dependency graph. Their target, advisory, and yank
results therefore differ. A clean product scan does not prove equivalent scope.
Keep the scheduled adapter's fresh-data and registry-failure checks above:
offline registry-index failures can exit zero in either raw CLI, so unavailable
data must not become a clean result.

Revisit consolidation when a supported cargo-deny interface can inspect the
complete, unpruned lockfile independently of the policy graph. At that time,
repeat the installed-tool controls, preserve precise advisory severities and
registry-failure reporting, and verify CI, scheduled/manual, and release callers
together. Until then, keep both tools, their immutable installation checks,
fresh-data execution, and the scheduled adapter's two-result completion rule.

Reusing the reviewed record keeps scanner version and build identity changes
atomic without creating a second registry or generated workflow declarations.
A separate record would split that update, while workflow scraping would couple
data validation to executable syntax. A wrong reviewed value remains a shared
failure source. Fixed scanner/source/layout allowlists, Windows archive digests,
executable probes and independent parser-semantic fixtures therefore remain
required. Changing a version does not establish compatibility with the runner's
supported report formats or registry-failure detection.

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
`Diagnostics` contains targeted GUI regression tooling;
`Historical` remains a recognized scope for old registries, but the retired
standalone chain has no current entries; selecting it here fails with no matches.
Reproduce historical tests from the pre-retirement checkout linked below.
Diagnostics are opt-in and remain registered. Use `All` when changing the runner
or shared code that affects every scope. Manual CI workflow dispatches run `All`
on both Ubuntu and Windows; push and pull-request CI retain `Current`. List the
current platform's selection or run a focused scope/category:

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
Shared Python fixtures are imported from support modules: `cli_fixture` builds
on `campaign_fixture`, which uses `menu_layout_fixture` and
`recovery_profile_fixture` (backed by `recovery_fixture`);
GUI suites use `gui_regression_fixture`. These helpers own sample data and
builders; their consuming suites own assertions and create fresh mutable state.
The current scope includes shared PNG/connection tests and a real evidence CLI
subprocess smoke test on Ubuntu and Windows. The smoke test uses synthetic
archives to check successful canonical output, incomplete-campaign rejection,
exit codes and private extraction cleanup; it does not execute a VM campaign.
On Windows, the PNG suite also executes the production capture bitmap
constructors with synthetic pixels through System.Drawing's encoder and the
independent evidence decoder. This checks format compatibility, without claiming
desktop capture or candidate acceptance.
The retired standalone acceptance tools and their schema are available only at
the immutable revision linked in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md).

## Tooling command ownership

Python owns portable planning, parsing and verification; PowerShell owns host,
guest, Hyper-V, UI Automation and Windows release integration. These are owners,
not interchangeable runtimes. Embedded C# remains a CLR/native-interop
exception. The completed file counts, language inventory and extraction
decisions belong to [issue #57](https://github.com/PiesP/DarkReNamer/issues/57)
and its [immutable implementation-era source](https://github.com/PiesP/DarkReNamer/blob/086d1044d07b2ec5a42b21b5bb4ddc435265d55e/DEVELOPMENT.md#L120).
The release-profile experiment retirement is recorded in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md#retired-release-profile-comparisons).

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
| `update-tooling-bundle.py` / Python generator | Python 3.11+ in the checkout; explicit source inventory, public CLI and PowerShell entrypoint templates, and `--check` | Regenerates the bundle manifest and self-contained public Python and PowerShell wrappers, or reports drift without writes under `--check`; `tooling-bundle` and `tooling-bootstrap` tests cover closure and rejection. |
| `tooling_bootstrap.py`, `tooling-bootstrap.ps1` / private authenticated loaders | Isolated Python or PowerShell 7.4+ after a public wrapper checks the pinned loader bytes; fixed manifest, role and layout | Validate and hold the required module closure, then expose verified import/scriptblock APIs. Bootstrap and bundle tests cover tampering, layouts and missing roles; neither loader is a general public CLI. |
| `test-windows-vm.py`, `run-vm-automated-campaign.py` / Python `vm` and `campaign` modules | Isolated Python on host/WSL, prepared VM connection, selected profile/source/candidate | Prepare and run source-bound native tests/campaigns, producing private bundles and receipts; registered VM, campaign, authority and cleanup tests cover contracts. Actual VM evidence is a separate gate. |
| `run-gui-regression.py` / Python `vm.gui` | Isolated Python on host/WSL, selected candidate and prepared VM; explicit diagnostic options | Produces bounded GUI diagnostic evidence. GUI diagnostic tests are opt-in; this command does not publish acceptance by itself. |
| `validate-gui-regression-evidence.py`, `validate-vm-automated-evidence.py`, `validate-vm-automated-authority.py` / Python `evidence`, `campaign`, `contracts` | Isolated Python, source identity and private evidence or authenticated hosted facts | Independent verdict/JSON or failure; evidence, binding, authority and GUI fixture tests cover malformed and successful input. Workflow callers retain artifact and GitHub authority. |
| `run-scheduled-rust-audit.py` / Python | Python 3.11+ on Ubuntu CI/security runners and hosted Windows candidate validation; checked-out lockfile, pinned scanners, fresh advisory data | Uses `SECURITY_TOOLS_ROOT/bin` on Ubuntu or explicit verified absolute `.exe` paths on Windows; validates versions, runs both scanners and rejects incomplete/data-failure results. `scheduled-rust-audit` tests and the three workflow callers own its invocation. |
| `build-patched-cargo-audit.py` / Python | Python 3.11+, the selected Rust toolchain and native linker; reviewed release-tool metadata and patched scanner lock | Requires a fresh `--work` directory and explicit `--destination`; verifies source/lock hashes before extraction/build, uses isolated Cargo state, then copies the exact-version binary. `--archive` accepts already downloaded verified bytes; `--verify-only` checks inputs without building. `scheduled-rust-audit` fixtures cover tampering and the locked build boundary; actual platform builds remain separate evidence. |
| `run-windows-vm-tests.ps1`, `windows-vm-guest.ps1`, `windows-vm-acceptance.ps1`, `windows-vm-recovery-acceptance.ps1` / PowerShell modules | PowerShell 7.4+; verified checkout or bundle role closure, host transport or guest session | Launch/control bounded native, UI and recovery work, transfer private evidence, and clean owned resources; registered VM/observer tests cover contracts. Windows runtime acceptance still requires the prepared VM. |
| `run-vm-automated-hosted.ps1` / PowerShell | Hosted Windows validation runner, authenticated candidate metadata and trusted source | Acquires/verifies handoff, invokes campaign and records gate outputs; `run-vm-automated-hosted` tests and `vm-acceptance.yaml` own this path. |
| `prepare-release-cyclonedx.ps1`, `measure-windows-binary.ps1`, `validate-release-candidate-metadata.ps1`, `validate-release-handoff.ps1` / PowerShell | PowerShell 7.4+; candidate files, exact Git revision or workflow metadata | Write only requested new output, emit digest/measurement/verdict, or fail; release category tests and release workflows cover their callers. Candidate validation does not promote a release. |
| `write-release-files.ps1` / PowerShell | PowerShell 7.4+ in the release candidate checkout; prepared handoff directory, source SHA, run ID/attempt, temporary root | Measures the prepared PE/PDB/archive, writes metrics and schema-2 handoff, embeds the tracked run instructions in the user ZIP, creates the support ZIP, then checksums only the finalized public ZIPs. The candidate workflow also requests a separate information-only footprint detail and measures a comparison-only combined ZIP outside the handoff. The registered release tests cover source/file binding, archive membership, actual CLI output and failure cleanup. |
| `get-release-product-notes.ps1` / PowerShell | PowerShell 7.4+; selected source and optional release tag | Reads the non-empty exact-version prepared section in `DISTRIBUTION.md`; candidate preparation checks it and promotion includes it alongside generated channel, provenance and support disclosures. |

Workflow inline code remains owned by each workflow. The remaining bounded
blocks have these owners and review triggers:

| Inline owner | Why it remains inline; extraction trigger |
| --- | --- |
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

The completed review in [issue #57](https://github.com/PiesP/DarkReNamer/issues/57)
retained `controller-entry.psm1`, `evidence/gui.py`, and
`ui-context-scenarios.ps1` as cohesive units. Their responsibility and caller
analysis is preserved in the
[immutable review text](https://github.com/PiesP/DarkReNamer/blob/086d1044d07b2ec5a42b21b5bb4ddc435265d55e/DEVELOPMENT.md#L192).
Revisit a split only when inventory/cleanup policy, a verdict family, or a UI
scenario needs independent maintenance. Preserve controller failure order,
independent GUI evidence verification, and shared observer session/capture
state. Update the authenticated role closure and run focused fixtures plus any
affected Windows cleanup or UI evidence.

The local Wine gallery was retired in issue #118 because its only remaining
callers were a historical reproduction command and its own diagnostic test.
The source-bound Windows GUI regression path remains a maintained visual diagnostic.
Review embedded C# whenever a native signature, marshalling, handle lifetime,
or UI boundary changes. The reviewed `guest-native.ps1`
blocks implement Win32 signatures/structures and handle lifetimes, UI Automation
provider registration, and the WinRT text-scale COM bridge. File-ID formatting
encodes the native identity, and the window-count cap bounds `EnumWindows`;
neither is a separate portable planner or serializer. Keep those ABI and cleanup
operations together. Its PowerShell Windows-root checks enforce the guest's
native filesystem contract; forwarding them to Python would add a guest runtime
without removing that contract.

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

The four PowerShell `.ps1.in` entrypoint templates retain their own public
parameters and workload flow. Their repeated pre-verification helpers come from
`scripts/powershell-bootstrap-helpers.ps1.in`; the three guest-side wrappers also
share `scripts/powershell-verified-tooling-initializer.ps1.in`. The host
initializer remains in its template because it verifies a fixed loader path and
accepts multiple roles. The generator rejects unregistered implementation files;
it does not discover new executable roles. Run the tooling gate after refreshing pins. Tooling checks
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

Pass `--expected-vm-id <guid>` to bind an ordinary SSH native run to that exact
Hyper-V guest. The controller reads the guest parameters from its own PSSession
and rejects a different identity before guest staging or task execution.
Without this option, ordinary source-built runs retain their existing behavior;
candidate and observer runs still require the expected identity.

Ordinary source-built runs also exercise the Korean, English and Japanese UI
through normal restarts. The maintained VM must resolve System to Korean for
the initial baseline; the observer reads Windows UI-language preferences and
rejects a different baseline instead of changing them. It checks saved language
selection, intact pending proposals, localized Apply/cancel and occupied-target
refusal, corrupt-journal locking, and default Cancel for a valid active recovery
journal made by the source-bound crash-test child. Original PNGs and independent
file-content/identity checkpoints stay in the private result bundle. Candidate
GUI-only and performance lanes retain their separate scopes. Repeat relevant
display configurations and inspect the original captures; a focused language
cycle does not establish the full GUI or release acceptance matrix.

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

### Virtual durable execution diagnostic

Measure actual backend renames and durable journal writes on the prepared VM
with an explicit source-built, non-elevated execution selection:

```bash
python3 -I scripts/test-windows-vm.py \
  --ssh-host "$DARKRENAMER_VM_SSH_HOST" \
  --expected-vm-id "$DARKRENAMER_VM_ID" \
  --virtual-execution-count 100 \
  --virtual-execution-iteration 1 \
  --output /absolute/private/new-virtual-execution-100-1
```

Resolve the configured SSH alias and guest GUID before running the command.
Counts are restricted to 100, 1,000 and 10,000; iterations are 0 through 5,
with zero explicitly recorded as warmup. Declare the count, iteration order
and fresh output roots before a series. Each invocation builds one exact-source
release backend test executable and runs only the ignored production-path
benchmark, with a 1,200-second deadline and the V2 owned-resource contract.
The maintained launcher owns the private fixture root and isolated environment.

This selection fixes `evidence_class=virtual-execution`, `media=virtual`,
`scope=vm-durable`, the baseline backend and same-parent topology. The existing
physical class and hosted planning workflow retain their original meanings.
Planning, preflight, fixture setup, execution, outcome verification and cleanup
have separate microsecond measurements. Backend and journal timings are nested
within execution and must not be added to it again. Source/binary identities,
operation counts, libtest transcripts and Job/controller cleanup are retained.
Completion requires unchanged contents and NTFS identities at the expected
destinations, a terminal removed journal and fixture removal.

Keep failed attempts and expected failure-path tests separate from successful
throughput. These instrumented virtual-storage results do not establish GUI
Apply latency, physical SSD/HDD performance, power-loss durability or release
acceptance. The validation-skip estimator is not an execution candidate.

### Windows runtime model baseline diagnostic

Run the fixed source-built model diagnostic on the prepared VM from a clean
committed checkout. Select the configured SSH alias, exact VM GUID, and a new
private output directory. The optional symbol directory must also be new,
absolute, private, and outside the checkout and bundle:

```bash
python3 -I scripts/test-windows-vm.py \
  --ssh-host "$DARKRENAMER_VM_SSH_HOST" \
  --expected-vm-id "$DARKRENAMER_VM_ID" \
  --profile-runtime-model \
  --private-symbol-output /absolute/private/new-model-symbols \
  --output /absolute/private/new-runtime-model-baseline
```

This selection fixes the v2 owned-resource cleanup profile, managed 1366×768
96-DPI RDP desktop, and a 1,200-second test and suite limit. It builds one
optimized app-library test binary plus the production executable from the
same source and runs exactly the ignored
`windows::list_view::native_tests::profile_runtime_model_baseline` test. The
optional private symbol directory retains the fresh executable/PDB pairs and
CodeView identities; the VM bundle does not contain PDBs. A passing
`validation-result.json` binds the source, test binary, complete stdout and
stderr bytes, exact libtest outcome, process Job, transport, and owned cleanup.

The test emits 183 schema-1 `runtime-model-baseline` records, with three
repetitions at 100, 1,000, and 10,000 model rows in each process. Each repetition includes
full preview uniqueness/collision groups, five single-row edit cases, four
model sort distributions, and native command sorting with none/sparse selection;
10,000 shuffled rows also include broad selection. The fixed verifier rejects
missing, duplicated, reordered, malformed, or out-of-range records. Setup and
functional assertions are outside the clocks. `compare_nested_ns` is included
in `sort_inclusive_ns`; do not sum those values. The sort-command record reports
separate selection snapshot, sort, token remap, native refresh, selection
restore, and post-control times. This is an instrumented Windows libtest/model
baseline, not production GUI Apply latency, process allocation count, heap peak,
or a user-visible responsiveness result. Keep actual product EXE and heap traces
as separate, source-bound evidence.

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

The helper profile must bind the SSH alias to the prepared VM. An ordinary
source-built SSH diagnostic may also supply `--expected-vm-id <guid>` to have
the controller check the connected guest before staging or task execution.
See [Native tests in a local Hyper-V VM](#native-tests-in-a-local-hyper-v-vm)
for the transport and identity requirements. The selector fixes a managed 1366×768,
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
refreshes, the existing unchanged 10,000-row refresh, a separate unchanged
10,000-row control with 20,000 unique valid minute-spaced FILETIME values,
proposal edits/resets, and long paths with auxiliary columns hidden and visible.
The native test checks row counts, representative text in all eight ListView columns even when auxiliary
columns are hidden, icons, and selection preservation. The current streaming
test emits `refresh-stages-distinct-filetimes-test-build` schema 4 with
`icon_worker_attached=false`: this is a detached UI staging measurement. Its
`row_values_inclusive_ns` contains `timestamps_nested_ns` and
`ui_shell_nested_ns`; `row_values_exclusive_ns` excludes both. The UI Shell
timings and call count, plus icon submissions and drains, must be zero.
`render_icon_cache_hits` and `render_icon_cache_misses` describe staging cache
lookups, not worker Shell calls. Schemas 3 and 4 include separate peaks for
one-row normal staging and full-vector fallback staging, retained rendered-vector
capacity bytes and growth events, and repeated nonzero FILETIME inputs. The new control
uses the same names, paths and sizes as the ordinary 10,000-row fixture, with
setup outside its timed refresh. It requires 10,000 formatted rows, 20,000
timestamp values, zero adjacent repeats and zero native cell writes. Historic
schema 3 receipts remain readable as their original 11-scenario shape; current
source-built bundles require schema 4 and all 12 scenarios. For the fixed
eligible workloads, normal staging owns at most one transient row and fallback
staging is zero. The repeated-input counter resets on each refresh and counts
adjacent identical nonzero values; it is a test-only input count, not evidence
of date caching. Vector capacity bytes describe the backing allocation, not
allocator or process peak memory. The native apply/rebuild clock excludes row
formatting. Historical `refresh-stages-icon-async-test-build` schema 2 retains
its original detached icon meaning, and `refresh-stages-test-build` schema 1
retains its synchronous Shell/cache meaning. The validator keeps all four
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

The owned-resources profile ID remains `vm-automated-v2-owned-resources`; its
current source blob, statement, and raw cleanup inventory are revision 3. The
controller captures a complete process inventory and any held protected OS
lifetime before minting the run name. Its source, bundle, VM, profile, native
lifetime, and held path proof stay bound through cleanup or the optional
same-session strict-failure finalizer. An omitted or newly opaque process still
blocks cleanup. The old revision-2 profile SHA selects only read-only historical
cleanup verification; it cannot enter the current campaign. See
[`SAFETY.md`](SAFETY.md#owned-resources-v2-runner-environment) for the exact
exception and its observation limits.

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

### Historical RuntimeBroker diagnostics

The frozen strict-v1 RuntimeBroker producer is retired. Its reproduction
entrypoint, pinned identities and evidence boundary are preserved in
[Historical Windows acceptance](docs/history/WINDOWS-ACCEPTANCE.md#retired-runtimebroker-producer).
Current v1/v2 evidence readers, GUI validation and cleanup contracts remain active.

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
`--acceptance-profile-id vm-automated-v2-owned-resources` selects the current
revision-3 owned-resource cleanup contract for this diagnostic only. The launcher
freezes the selected `config/vm-automated-v2.json` bytes and digest in each
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
invocation. Prepared reuse is restricted to declared performance,
first-clear-observation, picker-identity-observation, custom-input-identity-observation,
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

### Owned-resource fixed-performance sample

The fixed sample uses strict V1 cleanup by default. To select the separately
named revision-3 owned-resource contract, use a clean committed source and the
exact application already exercised by its native runner:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic performance-sample \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --performance-column-order hidden-visible \
  --prepared-bundle-root /absolute/private/verified-native-bundle \
  --expected-prepared-application-sha256 <native-executed-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-owned-performance-attempt
```

This route uses `performance-sample-v2-owned-r3-1366x768-96-text100-` run
IDs followed by `hidden-visible` or `visible-hidden`. It pins the reviewed
revision-3 profile bytes; a different profile requires a reviewed contract.
The fixed workload and timing scope above are unchanged. The explicit profile
branch retains the 600-second observer and 1,200-second controller limits,
5,000-ms command deadline, and one-PNG/32-MiB collection budget. No profile
fallback or automatic retry occurs.

The observer binds native PID and creation FILETIME through its original held
process handle, then requires normal exit and one closed sole-primary Job.
Actual pre-work and final text-scale snapshots must agree at effective 100%.
A present registry value must be `DWord` 100; successfully observed absence is
allowed only with an effective factor of 1.0. The sample does not change these
settings to satisfy admission.

The independent verifier retains complete process/task observations and ambient
deltas and requires the revision-3 owned-resource proof plus the indexed
managed-desktop start, stopped lease, and stop response. Failed preservation
uses the [pre-delete restoration gate](SAFETY.md#owned-resource-fixed-performance-diagnostic);
missing evidence leaves roots retained and the attempt incomplete. A successful
observation with incomplete cleanup is not a passing sample.

Report the selected contract and ambient delta ledger with the metrics. V2
owned cleanup does not prove V1 whole-session process stasis or harmless ambient
activity. Preserved V1 failures keep their original verdicts. Do not combine
V1 and V2 runs into a common timing baseline or balanced-order median; compare
products only under the same reviewed profile, workload, and desktop conditions.

### Focused picker identity observation

Use a clean committed source, its prepared source-built native bundle, and the
exact executable SHA observed by the native runner. Run one focused observation:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic picker-identity-observation \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --prepared-bundle-root /absolute/private/verified-native-bundle \
  --expected-prepared-application-sha256 <native-executed-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-picker-observation
```

The fixed run imports exactly 100 ordinary files once, with a 350-ms picker
settle interval. The sampler has a 120-second and 650-sample limit; the
controller has 120-second task and 240-second suite limits. Output is capped at
32 MiB and one screenshot. The revision-3 V2 profile, managed desktop closure,
owned process/task cleanup, pre-delete restoration gate, and failed first-record
preservation remain required. `sampler_failure` retains native lookup status,
failed predicates, owner chain, pre/post main identity, and QPC boundaries.
The independent verifier requires a source-selected schema and a sampled owned
picker interval. A failed or incomplete observation remains failed; this mode
does not run the fixed performance workload or complete performance acceptance.

### Focused first-10k-clear diagnostic

The current GUI controller no longer produces the frozen `focused-10k-clear`
observation. Its source-bound historical replay, original pins, receipt limits,
and pre-retirement reproduction source remain in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md#focused-first-10k-clear-observation).
The historical reader retains its exact recorded tooling-tree requirement;
validate old receipts from their recorded tooling revision. That single
observation cannot replace the fixed performance sample or a release verdict.

### Focused custom input identity observation

Run the source-bound custom input diagnostic with the same clean committed source,
prepared native bundle, executable SHA pin, and revision-3 V2 profile used for
the focused picker control:

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic custom-input-identity-observation \
  --acceptance-profile-id vm-automated-v2-owned-resources \
  --prepared-bundle-root /absolute/private/verified-native-bundle \
  --expected-prepared-application-sha256 <native-executed-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-custom-input-observation
```

The fixed run imports 100 ordinary files through the native picker control,
then opens the real `DarkReNamerInputWindow` twice. It confirms `confirmed-`,
verifies the proposal, resets it, enters `cancelled-`, cancels, and verifies that
the proposal stays reset. The first prompt is deliberately hidden for 700 ms
and restored before confirmation; the native visibility request is bounded to
five seconds and checks the same PID, thread, class, direct owner, and disabled
main window before and after. Each visible prompt remains open for a declared
350 ms. The sampler records source-selected schema-3 raw and accepted popup identities,
class, PID, thread, direct owner, owner chain, visibility, lookup status, and
failure predicates in the same probe brackets. The verifier requires a bound
`owned-hidden-inactive` custom sample during the controlled interval, a visible
sample after restoration, visible samples during both prompt intervals, and a
retired popup after cancellation. The controlled interval tests the policy; it
does not claim to observe a naturally timed creation or retirement transition.
If `GetLastActivePopup` does not expose the hidden prompt, the run remains a
preserved failure. The native picker is an independent control in the same run;
the custom prompt does not inherit picker class handling.

The observer has a 120-second and 650-sample limit, the controller has
120-second task and 240-second suite limits, and collection is capped at 32 MiB
and one screenshot. The V2 owned-resource, managed-desktop, failed first-record,
and pre-delete restoration requirements also apply. This focused diagnostic
checks each probe's native status/error pair and QPC-derived response time.
After the sampler stops, screenshot, fixture readback, journal readback, normal
close, or native exit errors retain completed samples and a bounded
`post_stop_failure` stage, separate from `sampler_failure`. Observer and
controller cleanup failures retain the original status and independent owned
cleanup proof; none become accepted observations. If conversion of stopped
native samples fails, the receipt instead records
`sample_transfer_failure` with a bounded reported raw count and final probe
tick. No converted samples or sampler failure are inferred from that report;
the independent verifier marks sample coverage unverified and still requires
the original failed status and owned cleanup proof before classifying the
rejected attempt. This focused diagnostic does not execute the complete
performance workload. Run and verify one complete
`performance-sample` after it; a failed or partial record cannot qualify the
full workload. Schema-2 receipts retain their prior `#32770`-only hidden-popup
meaning, while schema 3 additionally recognizes the exact custom input class
under the same native identity and lookup guards.

### First-clear failure observation

The `first-clear-observation` mode is a separate, one-attempt diagnostic of the
first 10,000-row clear on the current native-tested product. It requires a clean
committed checkout, a newly prepared source-built native bundle, an explicit
pin to that bundle's `application.sha256`, and the strict V1 profile. The
immutable input records the V1 profile file hash and compares the complete
non-tooling product/build Git inventory with
`d37f73cbb1e93dbc4334b6a92b0bdfbf4a8ddda2`. The new executable hash is
frozen separately; the historical executable is not reused.
The diagnostic and its independent verifier read the historical Git tree, so
the local checkout must contain that commit; a depth-one CI checkout cannot run
the diagnostic. Check this without changing the checkout:

```bash
git cat-file -e d37f73cbb1e93dbc4334b6a92b0bdfbf4a8ddda2^{commit}
```

```bash
python3 -I scripts/run-gui-regression.py \
  --diagnostic first-clear-observation \
  --acceptance-profile-id vm-automated-v1-win11-ntfs \
  --prepared-bundle-root /absolute/private/new-native-bundle \
  --expected-prepared-application-sha256 <new-bundle-application-sha256> \
  --connection-profile /absolute/private/connection-profile.json \
  --output-root /absolute/private/new-first-clear-observation
```

The observer keeps the fixed 30-second idle and 100/1,000/10,000-row import and
preview/reset prefix, then sends `WM_COMMAND 32782` once with the unchanged
5,000-ms native timeout. If that send times out with error 1460, it retains the
failed command and performs at most 50 passive slots over 10 monotonic seconds.
Each slot checks the original held process creation FILETIME and main/ListView
HWND identity before and after bounded, pointer-free count and responsiveness
queries with 50-ms native request limits. Missed slots, identity loss, and
actual wall-time overruns remain visible; neither a later zero row count nor a
structurally complete observation changes the failed command. The observer,
controller, and producer exits remain nonzero on timeout. The separate verifier
may report `failure-observed` only when all 50 bound slots and strict cleanup
are complete; otherwise it reports `incomplete`. Resource cleanup can pass
independently of the failed command. The raw original receipt and any failed
follow-up roots remain preserved. This mode never substitutes for the fixed
performance sample, native/GUI acceptance, or release evidence.

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

The pre-worker synchronous baseline uses a separate row-count upper-bound
method. Its frozen source/bundle invocation and distinct evidence limits are in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md#pre-worker-icon-settlement-baseline).
Row count bounds synchronous lookup completion; it does not observe actual icon
visibility, workers, queues or joins. Compare it with the candidate's observed
async endpoint only descriptively, recording both methods and censored attempts.
A new comparison must bind both source and prepared EXE before VM execution and
audit product Rust, Cargo and toolchain blob identity in any tooling-only
checkout; a manifest assertion alone does not prove it.

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

GUI tooling tests use the explicit diagnostic scope described in
[Tooling tests](#tooling-tests). Historical standalone tests are retired;
reproduce them from the linked pre-retirement revision. The retired Wine gallery
can be reproduced from the
[pre-retirement source](https://github.com/PiesP/DarkReNamer/tree/9df4d79e3891a1db6a5c4b6ff6ec63e7d4306ae5).

The manually dispatched `benchmark-planning.yaml` is an optional directional
measurement for a concrete planning investigation. Historical release-profile
comparison workflows and their reproduction entrypoints are recorded in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md#retired-release-profile-comparisons).
Reconsider the selected release profile when a new toolchain, workload, or size
constraint creates a concrete decision; reproduce the comparison from that
history before restoring automation. Directional measurements do not replace
source-bound Windows or release validation.

## Dependency policy

`Cargo.lock` and `--locked` define reproducible application resolution. Exact
manifest pins are reserved for the typed `windows` native-boundary dependency,
whose updates require focused Windows
validation. Other external dependencies use compatible requirements and remain
fixed by the lockfile. Review changes with the Windows target graph before
altering this policy:

```text
cargo tree --locked --target x86_64-pc-windows-msvc -e features
cargo tree --locked --target x86_64-pc-windows-msvc -d
```

Lockfile package counts include target-specific, build, and development
packages. They are not counts of crates linked into `DarkReNamer.exe`.

Import Names, Import Paths and destination-folder selection use a small typed
COM adapter in `windows/dialog.rs`. It shares creation, error classification and
owned exact UTF-16 extraction, while input selection and destination validation
remain separate from retained export authority. The pinned `rfd` backend erased
native failures into cancellation and converted Shell paths through `String`.
Retaining it with those gaps repaired would require maintaining a backend fork;
the native adapter reuses the existing STA, modal owner guard and Shell memory
owner instead. Shared COM errors can affect these three selections together;
operation policies and save/recovery event-sink ownership remain independent.
This dependency change makes no binary-size, speed or memory claim.

Ordinary source-built `scripts/test-windows-vm.py` runs exercise acceptance and
Cancel for these three pickers before the existing rename flow. The separate
`dialog_picker_checks` record binds each dialog to its process/session/owner,
checks titles and text filters, owner restoration and focus, exact multilingual
model results and unchanged cancellation/filesystem state. The host rejects
missing or incomplete observations. Candidate acceptance keeps its existing
separate contract; this focused development check is not a release verdict.

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
and review the official source or archive URL, full-byte SHA-256, patched lock
and extraction layout together.
The release-tool integrity fixtures cover wrong bytes before execution, stale
pins, unsupported assets and corrupt retained inputs. Complete the registered
release category and a non-publishing hosted candidate after pin changes;
fixture passes alone do not establish Windows installation or signing success.

### Production runtime baseline

From a clean source commit, use a prepared source-built bundle from that exact
commit and a new private output root:

```bash
python3 -I scripts/run-gui-regression.py \
  --output-root /absolute/private/new-runtime-baseline-attempt \
  --connection-profile /path/to/private/connection-profile.json \
  --diagnostic runtime-baseline \
  --prepared-bundle-root /path/to/source-bound/prepared-bundle \
  --expected-prepared-application-sha256 '<64-character-executable-sha256>' \
  --acceptance-profile-id vm-automated-v2-owned-resources
```

The fixed `runtime-baseline-v2-1366x768-96-text100` run requires the prepared
1366×768, 96-DPI, text-100, light managed desktop and a System language that
resolves to Korean. It starts three sequential fresh product processes with
separate isolated `LOCALAPPDATA` roots: absent preference with System selected,
valid saved System, and valid saved English. Every cell records the process
creation bracket, bound main window, empty list, enabled path-list import
command, exact preference record hash, localized menu radio state, VM region,
normal close, and owned process Job cleanup.

Startup retains raw QPC frequency and launch-request, process-creation begin/end,
exact main-window binding, and command-ready ticks. Main-window binding is the
observer's completed native-plus-UIA identity check, not the HWND creation time.
Separate launch/creation-bracket durations are reported for binding and command
readiness, plus binding-to-ready duration. The command-ready endpoint includes
foreground activation and empty-grid/import-menu observations. It precedes
capture sizing, native-lifetime verification, region and appearance probes.
The verifier checks raw boundary order and independently derives every reported
three-decimal millisecond interval, allowing at most 0.00051 ms rounding error.
Earlier failed attempts retain their original inclusive timing scope.

Each cell requires an absent `ui-appearance-v1` record before launch, with
the product's System appearance radio selected on its bound
PID/HWND/session. Existing native probes observe the official UISettings
foreground color and `SPI_GETHIGHCONTRAST` before launch, after readiness, and
before close. The verifier derives Light from the same foreground luminance
threshold used by the product and rejects dark, Forced Colors, missing probes,
or startup appearance overrides. After normal exit, the record may remain
absent or contain exactly the default System appearance: Automatic density,
Standard emphasis, and separators, preview tint, and empty safety enabled. The
24-byte `DRAPPR` version-1 record must pass length, header, enum, flag, reserved
byte, and FNV-1a checksum checks. Evidence retains its raw hex bytes, SHA-256,
and decoded values. Normal close queues and flushes a final appearance snapshot
even when the user made no appearance edits; file presence after close alone
does not establish an override. These observations do not change startup preferences
or OS appearance settings; appearance probes are outside the startup clock.

Only the first cell performs the workload: 30 seconds empty idle; one ordinary
1,000-file import; the existing asynchronous status endpoint with a stable full
icon generation; 30 seconds populated idle with the same settled generation;
then grow, shrink, and no-op manual-name proposals with reset verification and
unchanged fixture bytes. The existing 200 ms sampler retains raw CPU time,
private bytes, working set, thread, handle and GDI counts, responsiveness probes,
resource-query duration and sample gaps. Version 2 also retains each probe's
absolute QPC begin/end ticks and bound PID, process start, main HWND and thread
identity, using the startup clock's QPC frequency. The verifier checks interval
order, duration and identity across samples. Summaries are derived from those raw
samples. The scenario has a 600-second ceiling and one original populated PNG
within the existing 32 MiB evidence budget.

The independent GUI verifier requires the exact source/profile/prepared binary,
raw manifests and transcripts, all three process lifecycles and Jobs, normal
exits, text-scale restoration and managed-desktop cleanup. Missing icon or
populated-idle evidence is incomplete. The frozen strict-cleanup failure route
retains the failed original receipt and verifies all three process identities
before authorizing deletion of only its two held roots.

This diagnostic does not run Apply, measure allocator internals or process
wakeups, collect WPR traces, complete the unchanged fixed performance sample, or
provide release acceptance. The fixed performance sample continues to cover
100/1,000/10,000 rows, both long-path column orders, extension churn and reuse
with its existing schema.
