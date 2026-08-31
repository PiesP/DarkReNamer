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
- one benchmark each for 100, 1,000, and 10,000 entries on physical SSD and
  HDD media, with planning and execution durations, storage model and
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

The ignored Windows integration benchmark exercises the production planner,
`FileJournal`, and handle-relative rename backend on a caller-selected physical
volume. The root must already exist; the test creates and removes only its own
uniquely named child directory. Run all three counts once on an SSD root and
again on an HDD root:

```powershell
$env:DARKRENAMER_BENCH_ROOT = 'D:\darkrenamer-benchmark-root'
$env:DARKRENAMER_BENCH_MEDIA = 'hdd'
foreach ($count in 100, 1000, 10000) {
  $env:DARKRENAMER_BENCH_COUNT = "$count"
  cargo test -p darknamer-app --test rename_windows_backend `
    benchmark_durable_production_path --locked --release -- `
    --ignored --exact --nocapture --test-threads=1
}
```

Use `ssd` for `DARKRENAMER_BENCH_MEDIA` on the SSD pass. Record the emitted
durations and the required storage context in the external evidence artifact;
never copy the benchmark root into it. The media label is operator-supplied
context, not an automatic hardware claim, and results from virtual CI storage
do not substitute for either physical-media pass.

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
