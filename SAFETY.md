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
cross-volume, reparse, directory-move, and overlapping-source environments fail
closed.

Before freezing a directory rename, planning rejects any other requested source,
including an unchanged row, that is the same observed directory or lies below
it. A changed destination also cannot lie below a directory being renamed.
Observed directory identity resolves alternate accepted path spellings without
rewriting the model's source or destination text.

Planning resolves every changed source through one opened parent and source
handle. That result binds the source snapshot, actual directory-entry spelling,
and entry key. Duplicate candidates use the observed parent and file identities;
only no-op rows in a candidate group containing a changed row require the same
name resolution. Ordinary, verbatim, and available short-name aliases share one
source key while distinct hard-link names remain separate. A group containing
only unchanged rows remains inert.

Execution freeze resolves each changed source again before journal creation and
requires its snapshot, actual source spelling, and entry key to match the plan.
An identity-preserving external case or long-name change is therefore stale
source evidence and cannot begin a mutation.

Each primitive then opens its source with DELETE access while withholding
delete sharing. The retained mutation handle blocks competing rename and delete
opens through the native sink. Before mutation, the backend reads the actual
leaf from that same handle and requires an exact match with the frozen source
spelling; a mismatch or sharing conflict is `NotApplied`.

Destination collision, source-vacancy, schedule, temporary-name, and recovery
occupancy keys combine a frozen parent identity with one validated leaf name.
New journal Intents therefore store the actual source spelling needed by
rollback and later recovery. Existing journals retain their stored source text;
recovery does not guess or rewrite historical names. Correctness does not depend
on filesystem name tunneling after a rename.

The officially supported OS scope is Windows 11 and later on x64. Windows 10
may run the application, but is not tested or officially supported and is not
a release-acceptance target.

The v0.1 filesystem scope uses a local, non-elevated process operating on
same-parent, non-reparse entries in a case-insensitive NTFS directory.
Filesystems other than NTFS are unsupported
and unvalidated for v0.1. That limitation belongs to the release evidence
contract and the runtime boundary: DarkReNamer queries the filesystem from the
retained final directory handle and fails closed unless it reports NTFS.

Safe v2 retains `SameParent` as the authority for ordinary name changes. A plan
request selects `SameVolumeFilesOnly` only when the current model contains a
destination-parent proposal. That scope accepts regular files only, requires
the separately observed source and destination parents to be on the same local
NTFS volume, and preserves exact parent and file-identity checks before the
no-replace operation. The destination folder must already exist. The runtime
does not create folders, replace an occupied destination, merge directories, or
fall back to copy-and-delete.

Path unification is a proposal-only UI operation until Apply. It operates on all
rows and is unavailable when any row is a directory. After the folder dialog
closes, the application rechecks the owner session, model revision, close state,
recovery and mutation locks, and workers before changing the model atomically.
Cancellation, stale state, an invalid folder, or allocation failure leaves every
row and the revision unchanged. A successful change increments the revision once
and rebuilds path, collision, status, and Apply-readiness previews. Path reset
restores original parents while retaining proposed names; name reset restores
proposed names without changing target folders. Neither operation is filesystem
Undo.

Selected-row diagnostics and Apply details use owned snapshots of synchronized
model or frozen-plan data. Diagnostics do not validate filesystem occupancy or
create a rename plan or journal capability. Modal sessions prevent concurrent
model edits. The final confirmation defaults to Cancel and rechecks the original
session, revision, and plan fingerprint before execution; display expansion and
clipboard operations cannot rewrite the model or frozen plan.

Appearance preferences and repaints are non-authorizing input. Theme,
command-rail density and enabled-state painting, preview emphasis, separators,
tint, and empty-state copy may change presentation only. Preferences are stored
separately from rename journals and cannot alter model revision, plan identity,
Apply confirmation, mutation or recovery locks, or journal capabilities. Load,
write, theme, drawing, and layout failures use safe presentation fallbacks and
do not create filesystem authority. Native System and Forced Colors retain
Windows rendering; app-owned rendering must preserve command identity, keyboard
behavior, and MSAA/UIA metadata.

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

Journal format v2 persists the entry kind and move scope needed to recover an
authorized same-volume file move. Existing format-v1 journals remain readable
as legacy `SameParent` operations; decoding old recovery evidence never grants
it cross-parent authority. Rollback continues to reverse the exact source and
destination paths and their frozen parent identities.

No filesystem mutation may begin before the complete Intent is durable and the
candidate has atomically become the active journal. An append or rename whose
result is uncertain poisons the live capability: no further append, speculative
rollback, cleanup, or new mutation is allowed in that process.

Cancellation is linearized against journal begin. Before begin it produces no
journal or mutation. After begin it is observed only between complete primitive
steps and uses the same durable reverse-order rollback. Cancellation is ignored
from `Prepared` through rename reconciliation and throughout rollback.

The UI's Finalizing progress phase is published after all forward steps and
before the existing final cancellation check. It disables new UI cancellation
requests during commit; it is not a terminal result and grants no mutation
authority. In-flight cancellation requests still use the existing check. The UI
acknowledges a request without promising rollback, and reports only the actual
execution outcome. Rollback and terminal handoff also disable the Cancel control.

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
active stream, startup retains the opened handle and enters recovery lock
without changing any selected file. After the native window is visible, a
warning dialog requires an explicit custom-button confirmation before current
entry identities and occupancy are reconciled and rollback is attempted. The
dialog defaults to Cancel; cancellation, close, an unknown result, or a dialog
failure leaves the retained journal and recovery lock unchanged. Ambiguous
observations never cause a guessed rename.

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

The Safe v2 cross-parent path also has portable planner, schedule, journal,
recovery, model, and deferred-dialog regression coverage and is cross-compiled
for the Windows target. Those checks are not native Windows execution evidence.
Real Windows confirmation, common-dialog, filesystem, recovery, and interaction
results must remain `not-run` until source-bound acceptance evidence is recorded.

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

The native UI exceptions exist where Win32 handle, message, drawing, theme, and
subclass APIs cannot be expressed through the safe bindings. Those call sites
must validate window and object ownership, use owned snapshots instead of live
state references, release application state leases before reentrant Windows
dispatch, and restore borrowed drawing state and locally owned GDI resources.
Subclass state remains alive until confirmed detach or window destruction; an
ambiguous removal leaks the bounded context instead of risking dangling native
refdata. These presentation exceptions do not grant rename or journal authority.

`normalized_final_leaf` keeps the source handle live for the synchronous
`GetFinalPathNameByHandleW` call, passes either a null zero-length output or the
exact checked writable slice, bounds each allocation by
`MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS`, and retries a changed required size
once. It retains only a final component bounded by
`MAX_WINDOWS_LEAF_NAME_UTF16_UNITS`. Native API failures remain typed planning
blockers.

Rust toolchain or Windows binding upgrades, and every release-candidate review,
must re-evaluate whether safe `Default`, RAII ownership, typed COM wrappers, or
typed native APIs can replace any remaining exception before accepting the
current budget.

Those child-process terminations verify recovery after application-process
loss. They do not establish behavior across an operating-system crash, abrupt
VM or hardware power loss, storage write-cache loss, or power-loss durability
of directory-entry updates. Those cases require separate fault-injection or
manual acceptance evidence bound to the tested source SHA and storage setup.

## VM-Automated release validation

Release validation uses automated source checks, Windows backend tests, and
candidate-bound Windows VM observations under the fixed
[`config/vm-automated-v1.json`](config/vm-automated-v1.json) profile. Human input
and visual review are not required pass conditions and cannot substitute for
missing automated evidence. This changes the release evidence contract; the
filesystem, identity, no-replacement, journal and recovery invariants above
remain mandatory.

The profile is frozen before a campaign. It declares 22 target verdicts: two
core flows, 15 layout cells, and five recovery targets. The recovery-export and
Intent-only-discard targets share the process-crash execution group, so the
predeclared fixed matrix contains 20 primary execution cells. Ten additional
stability executions each run the core UIA flow under a newly created managed
RDP lease. They are independent executions, not retries, and do not claim a new
Windows logon session for each connection.

The 800 by 600, 100% DPI, 150% text cell predeclares the product's native
menu-only layout. Its main window and list must remain visible and bounded;
all 19 command-rail buttons must exist as hidden candidate-owned controls and
match the enabled states of their exact native menu commands. Actual keyboard
menu navigation must reach every enabled command without executing it, with
unchanged complete fixture and journal state afterward. The other layout cells
retain their visible command-rail and keyboard-focus requirements. Missing
rails never select a fallback during a run.

The complete campaign therefore has 30 predeclared first attempts. The plan is
written before VM access. Missing, failed, unavailable, environment-mismatched,
or incompletely cleaned attempts fail validation, and the controller stops
subsequent VM workloads after the first failure. A diagnostic archive may retain
that partial history, but a later retry cannot replace the failed attempt or
fill its missing slots. Passing requires a new campaign with a new complete
execution history.

The independent verifier derives all 22 target verdicts from raw observations;
producer summaries, `passed` flags, and legacy `review_required` values are not
verdict inputs. The five required gate records bind separate properties:

| Gate ID | Bound property |
| --- | --- |
| `locked-host-gate` | Authenticated successful exact-source CI jobs on master |
| `windows-backend-source-bound` | Exact-source native test binaries, their complete actual transcripts, and controller cleanup |
| `candidate-package-and-provenance` | Immutable candidate run, artifact, handoff, executable digest, and original GitHub provenance |
| `profile-raw-evidence-verifier` | Frozen profile plus the complete indexed raw-evidence derivation |
| `immutable-promotion-binding` | Exact candidate, private ingress, hosted validation run and attempt, and pinned master source tuple used by promotion |

The product source, clean harness source, and hosted validator checkout
must be the same commit. Candidate bytes are never rebuilt for the VM campaign
or promotion. An older candidate exercised by a newer harness remains a
development diagnostic and cannot satisfy this release contract.

| Previous requirement | Property checked by VM-Automated v1 | Evidence boundary |
| --- | --- | --- |
| Manual import, preview and Apply | Separate UIA and real keyboard flows; safe default Cancel; complete disk and journal invariance after cancellation; exact source-to-destination disk change | Immutable candidate EXE, actual input/focus records and complete checkpoint inventories |
| DPI, Forced Colors and small work areas | Every fixed display cell; actual HWND DPI, monitor/work-area bounds, exposed control geometry and focus reachability; setting restoration | Requested RDP values alone cannot pass a cell |
| Visual and accessibility inspection | Bounded decoded captures, UIA automation IDs, control types, visible/enabled/focusable states, geometry and defined keyboard navigation | No claim of human visual quality or comprehensive assistive-technology acceptance |
| Cancellation, close and process crash | Genuine partial mutation, complete original/restored file identities and contents, safe recovery default and journal locking | Process loss only; no VM reset, storage fault or power-loss claim |
| Recovery export and candidate discard | Export bytes equal the retained interrupted journal; explicitly injected candidate equals its authentic first Intent frame; explicit discard preserves files | Injected Intent is identified as injected, not a naturally observed crash artifact |
| Physical SSD/HDD benchmark matrix | Optional VM storage diagnostics only | Physical-device performance is outside the release claim |
| IME and Explorer drag-and-drop | Existing source/backend regressions where applicable | Actual IME and Explorer interaction are outside this fixed profile |
| Release packaging and publication | Immutable candidate identity, independently verified raw evidence and exact successful hosted validation attempt | Original candidate bytes plus an attested path-free validation statement |

The required backend regressions include a direct no-replacement primitive with
distinct occupied source and destination files. Both files' contents, sizes,
identities and the complete directory inventory must survive refusal. Planner
collision checks alone do not establish this primitive property. The gate keeps
the source-bound native test executables and complete stdout/stderr transcripts;
test names copied into a summary do not establish execution.

Recovery evidence records full `FILE_ID_INFO` identities: a 64-bit volume serial
and 128-bit file ID. The independent journal parser validates frame integrity,
payloads and state transitions, then binds Intent paths and identities to whole
fixture inventories. A pending Prepared operation may be either before or after
its on-disk rename; the observed state must match exactly one valid partial
prefix. Every protected sentinel remains outside the mutation schedule. A
product-supported final torn frame is retained with its raw length,
valid-prefix length, and tail kind. Only the complete valid prefix participates
in replay. Corrupt complete frames, invalid payloads and invalid transitions
fail validation; no bytes are
silently discarded to manufacture a passing trial.

Raw paths, user/VM identities, file identities, journals, images and logs remain
private external evidence. Frozen observer hashes must match trusted source;
the private archive is owner controlled and is not a remotely attested VM
measurement. The archive index, bounds, hashes and cross-bindings can detect
missing, substituted or inconsistent evidence, but they cannot prove that the
producer or VM administrator reported every observation honestly.

The hosted validation and promotion boundary is described in
[`DISTRIBUTION.md`](DISTRIBUTION.md#immutable-prerelease-promotion). An attestation
binds the checked statement and workflow execution; it does not make a
compromised VM or administrator a trustworthy hardware observer. The
owner-authenticated archive ingress still relies on the raw producer to report
actual execution;
raw consistency checking is not remote VM attestation. The hosted workflow
removes its private scratch and extracted archive before it returns success;
only then is the canonical path-free statement attested. Validation does not
authorize publication: tagging and publishing still require owner authorization.

## Historical Windows acceptance

The former manual desktop, physical-media, durability, observer, and diagnostic
procedures are retained in
[Windows acceptance history](docs/history/WINDOWS-ACCEPTANCE.md). They remain
valid for interpreting their source-bound historical artifacts, including every
failure, `not-run`, and `review_required` result. They do not define the current
release gate and are not evidence that any current VM-Automated campaign passed.
