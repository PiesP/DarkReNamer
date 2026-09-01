# Rename safety model

This document records the stable safety contract for DarkReNamer's maintained
Rust implementation. Compatibility quirks that affect only preview/list
semantics are separate from filesystem mutation authority.

## Assets and trust boundaries

Protected assets are the selected files and directories, unrelated entries in
the same parents, the exact active journal, and the user's ability to recover an
interrupted transaction. Paths selected through the UI, imported text, current
filesystem occupancy, reparse points, parent identities, and concurrent changes
by other processes are untrusted.

The UI may display paths but does not authorize mutation by string alone.
Planning freezes source, entry, and parent identities. The Windows backend
reopens and verifies those identities and performs handle-relative,
no-replacement renames. Unsupported network, device, case-sensitive, elevated,
cross-parent, reparse, and overlapping-source environments fail closed.

Appearance preferences are non-authorizing input. Theme, command-rail density,
preview emphasis, separators, tint, and empty-state copy may change presentation
only. They are stored separately from rename journals and cannot alter model
revision, plan identity, Apply confirmation, mutation locks, recovery locks, or
active and candidate journal capabilities. Preference load or write failure uses
safe presentation defaults and does not relax or create filesystem mutation
authority.

## Preview resource boundary

Name transformations are bounded before they can update the preview model.
`MAX_PROPOSED_NAME_UTF16_UNITS` owns the per-name UTF-16 limit and shares its
Windows component boundary with `MAX_WINDOWS_LEAF_NAME_UTF16_UNITS`.
`MAX_TOTAL_PROPOSED_NAME_UTF16_UNITS` owns the independent aggregate model
budget. Growing transforms calculate sizes with checked arithmetic, reserve
bounded staging storage fallibly, and commit changed rows only after every
candidate fits. A rejected parameter, size, aggregate budget, or staging
allocation leaves every proposal and the model revision unchanged.

Manual edits and imported names use the same boundary as prefix, suffix,
replacement, extension, parent-folder, digit-padding, and sequence commands.
The canonical values and error variants live in
`crates/darknamer-core/src/lib.rs`; Windows command error mapping lives in
`proposal_mutation_error_korean`.

## Transaction states

```text
No journal
  -> candidate created
  -> Intent durable
  -> active journal promoted without replacement
  -> Forward Prepared
  -> primitive rename reconciled
  -> Forward Completed or NotApplied
  -> Committed

Any nonterminal active state
  -> reverse-order Rollback Prepared
  -> rollback rename reconciled
  -> Rollback Completed or NotApplied
  -> RolledBack
```

No filesystem mutation may begin before the complete Intent is durable and the
candidate has atomically become the active journal. An append or rename whose
result is uncertain poisons the live capability: no further append, speculative
rollback, cleanup, or new mutation is allowed in that process.

Cancellation is linearized against journal begin. Before begin it produces no
journal or mutation. After begin it is observed only between complete primitive
steps and uses the same durable reverse-order rollback. Cancellation is ignored
from `Prepared` through rename reconciliation and throughout rollback.

## Release panic policy

The root `Cargo.toml` `[profile.release]` is the canonical panic policy. Release
builds use `panic = "abort"`: an unexpected Rust panic terminates the process
instead of unwinding into same-process UI recovery. Expected input, resource,
and I/O failures remain explicit `Result` paths and do not rely on panic
handling.

Worker `catch_unwind` and `Panicked` result branches provide supplemental
diagnostics only in unwind-enabled development and test builds. They are not a
release guarantee. If a release panic occurs after journal creation or
activation, recovery is delegated to the next launch's retained-journal
discovery and reconciliation. The terminated process makes no claim that it
rolled back or cleaned up uncertain journal evidence.

## Startup recovery and corrupt evidence

Startup first holds an exclusive runtime lock, then opens both fixed journal
leaves before taking a recovery action. If active and candidate are observed
together, both handles and their collision provenance are retained; automatic
rollback, cleanup, and candidate discard remain disabled. With only a valid
active stream, current entry identities and occupancy are reconciled before
rollback. Ambiguous observations never cause a guessed rename.

If bytes cannot be decoded, the UI starts recovery-locked and retains the exact
opened file handle when possible. It reports the path, failure stage, structured
kind, native code, codec frame, and observed size. Diagnostic export copies
valid active, valid candidate, and corrupt evidence from their retained handles
into new files only. An unavailable path is not reopened and an existing
destination is not overwritten.

A physically zero-byte candidate is removed automatically. A candidate that
contains exactly one complete Intent and no torn tail represents a plan that was
never activated and therefore never mutated selected files. With no active or
blocked artifact, the recovery UI may delete that candidate only after explicit
confirmation and an active-leaf recheck. It then rediscovers both fixed leaves
and unlocks Apply only when neither remains.

Otherwise only a strictly clean terminal journal may receive delete disposition.
Candidate and active names seen together, invalid or torn candidate content,
poison, promotion uncertainty, or any cleanup error keep Apply locked.

## Verification expectations

Behavior tests cover chains, swaps, cycles, case-only changes, stale identities,
destination races, hard links, reparse points, journal tears and corruption,
append uncertainty, cancellation, and reverse rollback. Windows child-process
tests terminate after each durable/mutation boundary and restart through the
production recovery path. They assert expected original or committed names,
unchanged sentinel files, no temporary names, and either terminal cleanup or an
explicit recovery lock.

Capability-dependent Windows tests may report a structured local skip through
`tests/support/windows_capabilities.rs`. The hosted Windows and prerelease gates
set that module's required mode, so an unavailable case-sensitivity query,
reparse fixture, or journal-root capability is a failing gate rather than a
successful test. Hosted commands retain the capability result in their logs.
Source-inspection tests embed the exact workflow and Rust source inputs selected
at build time. A test binary cross-built on one host therefore inspects those
same inputs when executed elsewhere; it does not depend on a compile-time path,
current directory, executable location, or runtime-selected checkout.

### Unsafe boundary policy

`darknamer-app` denies unsafe code by default, and the non-Windows library raises
that policy to `forbid`. Narrow exceptions are attached only to the native UI
module declaration in `src/lib.rs`, the two Windows rename adapter declarations
in `src/rename/mod.rs`, and the native backend integration-test crate. Code
outside those boundaries must remain safe Rust.

`unsafe_source_inventory_matches_the_reviewed_budget` in
`tests/unsafe_policy.rs` enforces exact per-file lexical budgets. Those budgets
are review caps rather than evidence of soundness: additions fail, and removals
must lower the corresponding budget in the same reviewed change. Every modified
exception still requires a local `SAFETY` justification and must pass the
Windows Clippy gate while `undocumented_unsafe_blocks` and
`unsafe_op_in_unsafe_fn` remain denied.

Rust toolchain or Windows binding upgrades, and every release-candidate review,
must re-evaluate whether safe `Default`, RAII ownership, typed COM wrappers, or
typed native APIs can replace any remaining exception before accepting the
current budget.

Those child-process terminations verify recovery after application-process
loss. They do not establish behavior across an operating-system crash, abrupt
VM or hardware power loss, storage write-cache loss, or power-loss durability
of directory-entry updates. Those cases require separate fault-injection or
manual acceptance evidence bound to the tested source SHA and storage setup.

## Windows acceptance evidence

Windows acceptance is recorded as a local or external JSON artifact. Evidence
files are not source files, must not be committed, and must not contain local
paths, operator or machine identities, or volume serials. The JSON records a
full source SHA and the tested executable's filename and SHA-256. An artifact
from the Actions handoff also records its workflow run ID; a local build is
identified only as a local build. The validator does not retrieve either
artifact, so the operator remains responsible for hashing the executable that
was actually exercised.

For a release decision, validate the complete external evidence against the
downloaded Actions handoff and matching checkout with
[`scripts/validate-release-acceptance.ps1`](scripts/validate-release-acceptance.ps1).
This cross-check requires the evidence to identify `actions-handoff` and match
the handoff's source SHA, workflow run, executable filename, executable digest,
and actual executable bytes. Packaging validation by itself does not satisfy
the acceptance matrix below.

[`scripts/windows-acceptance-evidence.schema.json`](scripts/windows-acceptance-evidence.schema.json)
is the machine-readable field contract. Validate evidence with
[`scripts/validate-windows-acceptance-evidence.ps1`](scripts/validate-windows-acceptance-evidence.ps1).
The validator requires PowerShell 7.4 or newer and is invoked with `pwsh`.
The default mode is the release gate. `-Draft` is for an intentionally
incomplete session; it still validates structure, source and artifact binding,
privacy, uniqueness, and references. Every omitted draft target and every
`not-run` row must point to a reason in `unexecuted`. Draft validation never
promotes missing work to release evidence.

Complete release-gate evidence requires all of the following:

- one unique UI result for Windows 10 and Windows 11 at 100%, 125%, 150%, 200%,
  250%, and 300% DPI in both normal and high-contrast modes (24 cells total),
  all passed;
- one passed result per operating system for keyboard-only operation,
  accessibility inspection with tool and version, Explorer drag-and-drop,
  common dialogs, clipboard, worker cancellation, worker close, startup
  recovery, recovery export, and Intent-only candidate discard;
- one same-parent benchmark each for 100, 1,000, and 10,000 entries on physical
  SSD and HDD media, with planning and execution durations, storage model and
  connection, free-space bucket, power mode, and a clean cleanup observation;
  and
- a passed application-process crash trial plus at least one separately
  authorized and passed VM hard-reset or storage-fault trial.

Physical power-loss evidence is an optional stronger trial. Process exit, VM
hard reset, storage fault injection, and physical power loss remain distinct
trial classes. Evidence from one class never establishes or substitutes for
another. Every omitted durability class and every `not-run` durability row
links to an explicit `unexecuted` reason, including optional and alternative
classes. A failed recorded durability trial does not pass the release gate.
An executed VM, storage-fault, or physical-power trial records only the
`operator-authorized` scope marker, never the approver's identity.

The JSON is deliberately path-free and has no generic note or narrative field.
UI, scenario, durability, and unexecuted results use enumerated observation and
reason codes. It stores an artifact filename, not its location, and uses
bounded free-space categories instead of volume details. Accessibility tool
and storage model-family values accept only a restricted character set. The
operator must record the public model family, not a device serial, asset tag,
operator name, or hostname.

Screenshots, traces, detailed narratives, benchmark roots, user profiles,
hostnames, and operator names remain outside the JSON. Name an external
evidence artifact `windows-acceptance-evidence-<source-sha>.json`; CI rejects a
tracked file matching that evidence pattern. A release decision must cite the
external artifact through the release's controlled handoff rather than add a
current run's SHA, timestamp, measurements, or machine details to this
document.

### Durable workload benchmark

The ignored Windows integration benchmark's `baseline` variant exercises the
production planner, `FileJournal`, and handle-relative rename backend on a
caller-selected physical volume. The estimate variant is the narrowly bounded
planning-only exception described below. The root must already exist; the test
creates and removes only its own uniquely named child directory. Use a dedicated
root whose access is private to the benchmark operator and run it from a
non-elevated PowerShell session. The private-root environment setting below is
an explicit operator acknowledgment, not an ACL check.

The authoritative physical matrix is SSD and HDD media crossed with counts 100,
1,000, and 10,000 and the `same-parent`, `unique-parent`, and `deep-parent`
topologies. Run iteration 0 once as a warmup for every matrix cell, then record
iterations 1 through 5. Select the correct dedicated root and media value for
each physical device:

```powershell
$env:DARKRENAMER_BENCH_ROOT = 'D:\darkrenamer-benchmark-root'
$env:DARKRENAMER_BENCH_MEDIA = 'hdd'
$env:DARKRENAMER_BENCH_ROOT_PRIVATE = '1'
$env:DARKRENAMER_BENCH_EVIDENCE_CLASS = 'physical'
$env:DARKRENAMER_BENCH_VARIANT = 'baseline'
$sourceSha = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceSha -cnotmatch '^[0-9a-f]{40}$') {
  throw 'Could not resolve an exact lowercase source SHA.'
}
$env:DARKRENAMER_BENCH_SOURCE_SHA = $sourceSha
$env:DARKRENAMER_REQUIRE_WINDOWS_BACKEND_CAPABILITIES = '1'
foreach ($count in 100, 1000, 10000) {
  foreach ($topology in 'same-parent', 'unique-parent', 'deep-parent') {
    foreach ($iteration in 0..5) {
      $env:DARKRENAMER_BENCH_COUNT = "$count"
      $env:DARKRENAMER_BENCH_TOPOLOGY = $topology
      $env:DARKRENAMER_BENCH_ITERATION = "$iteration"
      cargo test --package darknamer-app --test rename_windows_backend `
        benchmark_durable_production_path --locked --release -- `
        --ignored --exact --nocapture --test-threads=1
      if ($LASTEXITCODE -ne 0) { throw 'Benchmark failed.' }
    }
  }
}
```

Use `ssd` and the SSD's dedicated root for the SSD pass. Only the six
`same-parent` cells (two media classes by three counts) map to the existing
release-acceptance benchmark rows, and those rows must use `variant=baseline`.
Keep `unique-parent` and `deep-parent` results as separate, source-SHA-bound,
path-free diagnostic evidence; they do not add or replace release rows. Record
only iterations 1 through 5. Iteration 0 is warmup output and must not be
promoted to evidence.

For each of the six `same-parent` release rows, record the median
`planning_ms` and median `execution_ms` from the five recorded iterations.
All five iterations must have emitted their result lines after clean fixture
cleanup. Preserve all five raw path-free metric line sets in the external,
source-SHA-bound performance record. Never select a single or best-performing
iteration, and never include warmup iteration 0 in the median. The
`unique-parent` and `deep-parent` samples remain diagnostic and are not
aggregated into release-acceptance rows.

The summary line reports the whole `planning` and `preflight` phases and, for
physical evidence, the durable `execution` phase. Backend lines report
`planning`, `preflight`, and `execution` call counts and observer timings;
journal lines report the execution journal phases. The per-call observers add
measurement overhead, so their microseconds are diagnostic attribution and do
not sum exactly to wall-clock duration. The benchmark removes its fixture
before emitting any result lines: missing output after work begins can indicate
cleanup failure and is not a usable measurement. Every emitted summary,
backend, and journal line carries the exact source SHA and instrumentation
revision.

Establish a fresh five-iteration baseline on the exact source SHA before an A/B
run. The paired run must use that same source SHA,
`instrumentation_revision=parent-validation-v1`, machine, volume, power mode,
toolchain, count, topology, warmup, and five recorded iterations. A prior
baseline is not reusable after any of those conditions or the instrumentation
revision changes.

`DARKRENAMER_BENCH_VARIANT` defaults to `baseline` and also accepts the
benchmark-only `validation-skip-estimate`. The estimate skips repeated parent
validation to provide a conservative directional comparison in a controlled,
private, static fixture. Concurrent parent mutation invalidates that assumption, so matching
plan rows and fingerprints in the fixture do not establish behavioral parity.
The wrapper is consumed immediately after planning; preflight, execution,
freeze validation, and mutation use the unwrapped production backend. The
estimate retains no handle or snapshot and is not an implementation prototype
or production candidate.

Run `baseline` and `validation-skip-estimate` separately under the paired
conditions above. Both variants use the same timing instrumentation, and the
median rules remain unchanged. Estimate results are diagnostic even on physical
SSD or HDD media and can never populate, substitute for, or approve a
release-acceptance row. Baseline remains the only release evidence.

Production validation/observation fusion remains no-go unless a typed atomic
inspection seam can return a validated observation without carrying cached
authority across the planning boundary. A production decision additionally
requires separate paired physical evidence showing stable median improvement
across SSD and HDD media at 100, 1,000, and 10,000 entries for all three
topologies, plus safety and execution regression coverage. The skip estimate
cannot satisfy or waive either requirement.

The media label is operator-supplied context, not an automatic hardware claim.
The manual `Planning benchmark` Actions workflow uses ephemeral runner storage,
`directional-hosted` evidence, `virtual` media, iteration 0 warmups, and one or
three recorded repetitions. Its planning-only output is useful for directional
regression checks, but is neither physical-media evidence nor release-acceptance
evidence and does not replace the physical matrix above. Dispatch it separately
for `baseline` and `validation-skip-estimate` when collecting a paired
directional comparison. Both dispatches must use the exact same source SHA and
`parent-validation-v1` instrumentation revision; do not combine variants in one
run.

### Preview path-key benchmark

The ignored Windows-only preview benchmark measures the complete preview
diagnostic pass at 100, 1,000, and 10,000 rows using the production
`WindowsRenameBackend::path_key` implementation, including invariant Windows
UTF-16 case folding. Run it in release mode on the source under acceptance:

```powershell
cargo test -p darknamer-app --lib `
  windows::list_view::native_tests::measure_preview_validation_with_production_windows_path_keys `
  --locked --release -- --ignored --exact --nocapture --test-threads=1
```

The emitted `validation_us` values measure validation and path-key generation;
they do not measure native ListView repaint latency. Record interactive preview
responsiveness separately in the source-bound Windows UI acceptance session.
