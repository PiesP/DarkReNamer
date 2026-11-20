# Journal protocol verification

Run the bounded check and its negative controls from the repository root
with Java 21, Bash, curl, and sha256sum. The runner downloads the pinned
TLA+ Tools v1.7.4 JAR (TLC 2.19) and verifies its SHA-256 before execution.
Set `TLA2TOOLS_JAR` to the path of an existing copy to run without downloading
it. The same digest check applies. [Upstream release](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)

```bash
bash scripts/check-journal-model.sh
cargo test -p darknamer-app --test rename_executor journal_contract --locked
```

## Finite model

[JournalRecovery.tla](JournalRecovery.tla) explores one active journal with one
same-parent file rename, two names, one selected identity, and at most one
foreign identity. It starts with the selected identity at its original name
and allows three restarts. The bound is ten complete records, including
repeated rollback preparations and outcomes. All enabled orders within these
bounds are explored with one TLC worker. Interruption and uncertainty permit
restarting after the last durable state. Interrupted, blocked, terminal, and
restart-exhausted runs may stop. Recovery completion has no fairness or
liveness assumption.

The journal prefix, the current file position, and the executor's knowledge
are distinct variables. Activating the journal represents an acknowledged,
durable Intent and successful promotion. Each modeled append can acknowledge
a complete record or lose its result with or without persistence. A forward
or reverse rename can acknowledge success, reject without a move, or return
an uncertain result in either physical state. A restart rebuilds knowledge
from the retained prefix and observes both names before reconciling a pending
move. An observed rollback that did not apply can be retried during that
recovery. A foreign entry may appear in an empty name, including after
recovery observation. The move checks the destination again as part of its
identity-bound no-replacement assumption.

The oracle derives the expected identity position from durable completed
records. A different position needs a matching outstanding preparation. The
checker also verifies the terminal record sequence independently of physical
position. Every preparation in a terminal stream must have resolved in the
same direction. Committed requires a forward completion and no rollback
preparation. RolledBack requires a rollback completion for each forward
completion. The checker enforces the record bound and checks that a halt or
block stops changes to the selected identity and program-issued records until
restart.

Two negative configurations exercise the checks. `UnpreparedMove` moves the
file with only an Intent and violates `PositionExplained` at state 3.
`PrematureTerminal` loses the preparation acknowledgement, restarts, observes
the file at its original name, and appends RolledBack before resolving the
outstanding preparation. It violates `TerminalEvidenceResolved` at state 6.

The model treats a stored record as an atomic whole and represents an invalid
retained stream with a corruption flag. Its assumptions include a single
executor at a time, fixed parent identities, and no external removal or
replacement of the selected identity. Existing corpus and fault tests cover
byte-level and multi-step cases. Native identity, no-replacement, namespace
and stream exclusion, and physical storage durability scope remain defined
by the safety contract. Process termination exercises recovery with surviving
records and filesystem state. Power loss and write-cache behavior require
their own observations. [Rename safety model](../../SAFETY.md)
[Codec corpus](../../crates/darknamer-app/tests/journal_codec_corpus.rs)
[Recovery fault matrix](../../crates/darknamer-app/tests/rename_recovery.rs)

## Production replay

The `journal_contract_*` tests use the existing fault adapters and
`RenameExecutor` and `RenameRecovery` entry points. Journal calls are recorded
alongside rename attempts, and separate assertions inspect the retained
records and identities. A fixture restart opens a fresh in-memory journal
capability from the retained records and preserves the filesystem fixture.

| Model event | Observation through the production path |
| --- | --- |
| `Activate`, `PrepareForward`, uncertain rename | The same Intent and Prepared records, error code, indeterminate entry, and recovery-required report for both physical outcomes. No later append or rename runs in that execution. |
| `Restart`, `ObservePending` | At the destination, recovery appends forward Completed before preparing and performing the reverse rename. At the original name, it appends forward NotApplied and issues zero reverse renames. Both end in RolledBack and a second restart takes no action. |
| Uncertain rollback, then restart | The first recovery leaves rollback Prepared with the file still at the destination. The next recovery appends rollback NotApplied, prepares again, and restores the identity. |
| `Commit` | Forward Completed precedes Committed. The destination retains the selected identity and restart takes no action. |
| `CreateForeignEntry`, `DamageRecords` | Recovery blocks on an occupied original name or either terminal record over an unresolved preparation. Each terminal case places the selected identity at that terminal's expected name. The test checks retained records, identities, and absence of later effects. |

The Rust tests use explicit expected reports, records, ordering, and identities
derived from these contract cases. The model does not import an implementation
or use past executor output as an oracle. The fixture restart exercises logical
recovery. Native child-process restart coverage is owned by the existing
Windows tests and acceptance procedures.
[Replay tests](../../crates/darknamer-app/tests/rename_executor.rs)
[Windows restart tests](../../crates/darknamer-app/src/windows.rs)
