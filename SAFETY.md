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

Those child-process terminations verify recovery after application-process
loss. They do not establish behavior across an operating-system crash, abrupt
VM or hardware power loss, storage write-cache loss, or power-loss durability
of directory-entry updates. Those cases require separate fault-injection or
manual acceptance evidence bound to the tested source SHA and storage setup.

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
