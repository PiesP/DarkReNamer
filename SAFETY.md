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

Startup exclusively opens the exact active journal. A valid nonterminal stream
is reconciled against current entry identities and occupancy before rollback.
Ambiguous observations never cause a guessed rename.

If bytes cannot be decoded, the UI starts recovery-locked and retains the exact
opened file handle when possible. It reports the path, failure stage, structured
kind, native code, codec frame, and observed size. Diagnostic export copies from
that handle into new files only; an unavailable path is not reopened and a
corrupt journal is never automatically deleted.

Only an empty pre-mutation file or a strictly clean terminal journal may receive
delete disposition. Candidate and active names seen together, invalid candidate
transitions, poison, or any cleanup error keep Apply locked.

## Verification expectations

Behavior tests cover chains, swaps, cycles, case-only changes, stale identities,
destination races, hard links, reparse points, journal tears and corruption,
append uncertainty, cancellation, and reverse rollback. Windows child-process
tests terminate after each durable/mutation boundary and restart through the
production recovery path. They assert expected original or committed names,
unchanged sentinel files, no temporary names, and either terminal cleanup or an
explicit recovery lock.

Native release acceptance must additionally cover Windows 10 and 11, multiple
DPI values, high contrast, keyboard operation, accessibility inspection,
worker cancellation/close behavior, and representative 100, 1,000, and 10,000
entry workloads. Unexecuted matrix cells must be reported rather than inferred
from unit tests.

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

Use `ssd` for `DARKRENAMER_BENCH_MEDIA` on the SSD pass. Preserve the emitted
planning and execution milliseconds together with the exact source SHA,
Windows version, storage model, connection type, free space, and power mode.
The media label is operator-supplied context, not an automatic hardware claim,
and results from virtual CI storage do not substitute for both physical-media
passes.
