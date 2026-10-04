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

Production recovery state is rooted under the selected local `LOCALAPPDATA` on
NTFS. The runtime retains every directory handle from the drive root through
`DarkReNamer/journal` without delete sharing. It reads the owner and DACL from
each retained handle. Ancestors may be owned by the user, SYSTEM, built-in
Administrators, or the exact Windows TrustedInstaller service SID; other
principals may traverse/read but may not replace a child or change its ACL or
owner. The two application-owned directories and all recovery files must be
owned by the current process user; only that user, SYSTEM, and built-in
Administrators may receive read, write, delete, or control rights. Both explicit
and inherited allow ACEs are inspected; unrecognized ACE forms and null DACLs
fail closed. A deny ACE does not make an unsafe allow ACE acceptable. New state
objects receive a protected DACL before creation. The runtime lock must have
one hard link. Pre-existing unsafe state is never repaired and trusted in the
same startup: unsafe directories or lock files stop startup, while unsafe active
or candidate journals remain retained, block Apply, and preserve their bytes.
This protects against a different non-admin principal with access through a
permissive profile or state ACL. It does not authenticate historical contents
written while that boundary was absent; previously shared evidence should be
quarantined for separate review. Same-token processes and administrators remain
outside this ACL boundary. Checksums and strict replay validate structure, not
the origin of old journal records.

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

Save Names and Save Paths create new files only. Existing destinations,
including hard links, directories and reparse points, are never overwritten;
the user must choose an unused file name. While the save dialog is open, the
application binds the selected folder's shell volume/file identity to a retained
no-reparse local NTFS directory chain. Every ancestor remains open without
delete sharing. Session and revision revalidation still precede writing.

Export bytes are written, flushed and synchronized to a uniquely named sibling
opened exclusively. The same staging handle remains open with no sharing through
the final handle-relative no-replace rename. The final native operation refuses
any later occupant, including one introduced immediately before commit; it does
not reopen a target name for replacement. The stage inherits the selected
folder's new-file permissions, which are also the intended new destination's
permissions. An intentionally shared new export is not given an existing private
file's DACL. Failure cleanup deletes only the retained owned staging handle and
never reopens a possibly substituted temporary name. A cleanup failure reports
that temporary evidence may remain. There is no existing-file replacement,
metadata merge, replacement backup, or target-release interval in this path.

UTF-16LE imports reject an incomplete trailing code unit and retain complete
UTF-16 code units, including unpaired surrogates, for legacy path handling.
Text imports use one bounded result handoff and perform open, opened-handle
regular-file metadata validation, bounded read, and decode on a worker thread.
The selected import location remains unrestricted, including network/provider
paths, so a provider can leave synchronous I/O pending for an unbounded time.
Cancel and close request `CancelSynchronousIo` through the tracked
`JoinHandle`'s native thread handle, created by Rust's Windows `CreateThread`
path with cancellation access. Both requests mark the result discard-only.
The worker checks the shared cancellation flag before open, handle metadata,
and every bounded read, and after I/O before decoding. An observed request stops
new I/O, including retries of interrupted reads. The existing live-window poll
reissues native cancellation while retirement is pending, covering the gap
between a flag check and a native call. A failed native cancellation request
still leaves the result discard-only, and no request promises immediate completion. The UI remains responsive, while the
dialog session and runtime lock remain held until the worker thread reaches
its terminal state and the UI joins it. A successful late read after cancellation
cannot update the model. On completion the UI rechecks the saved session,
revision, close state, and mutation/recovery locks before committing name
proposals or handing bounded paths to admission. No worker borrows `AppState`
or performs UI/model mutation. The wake carries no pointer and a live-window
timer provides a missed-wake fallback. Controlled stage-delay tests exercise
the lifecycle, but do not establish a deadline for any real provider.
If the Win32 message pump itself fails while import I/O is still pending,
normal close processing is unavailable. The process captures the message-loop
error, writes it to standard error where available, and aborts, ending all
threads and releasing the runtime lock together
instead of joining indefinitely on the failed UI thread or dropping the lock
while an import thread still runs. This fatal path does not delete journal
evidence and import has no filesystem mutation authority. A defensive
`AppState` teardown check applies the same process-fatal rule if unexpected
window destruction bypasses the normal close gate while import I/O is live.
The multi-select file picker extracts only the remaining source capacity plus
one overflow witness, and it stops after the aggregate UTF-16 path budget is
exhausted before building additional path values.

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
Clipboard copy fully allocates, fills, and unlocks its data block before opening
or emptying the clipboard, so preparation failures preserve the previous data.

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
These per-name and aggregate UTF-16 limits bound specific input and model data;
they do not bound total process memory or make every allocation failure a
recoverable UI error. The release `panic = "abort"` behavior and next-launch
journal recovery are described below.

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

On Windows, an existing journal is accepted only when its retained file handle
reports exactly one hard link. This prevents recovery append, torn-tail
truncation, and journal disposition from changing an unrelated alias. A file
whose link count cannot be observed is retained as invalid evidence and remains
recovery-locked.

The recovery-export folder is bound while its native folder picker is open.
The application retains the selected local NTFS directory chain and shell
volume/file identity, then creates each fixed evidence leaf relative to that
retained directory handle with exclusive, no-reparse creation. Replacing the
selected path after acceptance therefore cannot redirect evidence into a
different folder.

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
module declaration in `src/lib.rs`, the `private_state`, `windows_backend`, and
`windows_native` declarations in `src/rename/mod.rs`, and the native backend
integration-test crate. Code
outside those boundaries must remain safe Rust.

`unsafe_source_inventory_stays_within_reviewed_native_boundaries` in
`tests/unsafe_policy.rs` restricts unsafe constructs to explicitly reviewed
locations and construct kinds. Unlisted locations, unsafe implementations,
unsafe traits, unsafe attributes and mutable statics fail the gate. Lexical
counts are diagnostic, not evidence of soundness; reducing allowed unsafe usage
does not require a synchronized count table. Every modified exception, including
additions within an allowed location, still requires native-boundary review and
a local `SAFETY` justification. The Windows Clippy gate keeps
`undocumented_unsafe_blocks` and `unsafe_op_in_unsafe_fn` denied.
`rename/private_state.rs` is the reviewed exception for querying token SIDs,
handle security descriptors and ACEs and passing a protected descriptor to
the parent-relative `NtCreateFile` creation boundary. The descriptor and SID
buffers remain live for each synchronous native call; all LocalAlloc outputs
are released once. Unknown security forms fail closed before journal decoding.
Successful descriptor, DACL and ACE outputs are explicitly checked for null;
ACL/ACE dereferences use checked `NonNull` values while the descriptor remains owned.

The TaskDialog source guard checks identifiers and dynamic-lookup source strings.
It does not measure a compiled executable's PE import table.

The following bounded design dispositions retain existing behavior:

- **CallbackState / CallbackStateLease: retain the current protocol.** A sole
  UI-thread lease rejects nested borrowing; destruction removes publication and
  defers exactly one reclamation until that lease ends. Retirement and color
  sidecars remain disjoint from the leased value. An optional UI-thread run hold
  can defer reclamation further while a tracked worker is retiring: an
  unpublished slot remains unleaseable after either the callback lease or hold
  ends, and is freed exactly once after both end. This keeps the AppState's
  last-dropped runtime lock alive until the worker has actually joined without
  moving a native state pointer to that worker. An Rc-backed owner with
  RefCell::try_borrow_mut could replace borrowing/reclamation internals, but must
  also retain a strong owner before callback dispatch, remove publication before
  destruction, and keep sidecars independently accessible during a value borrow.
  RefCell alone does not keep a destroyed window's allocation alive. A UI-thread
  registry would additionally require explicit registration/removal and generation
  checks for reused HWNDs; an HWND alone is not a lifetime token. Either approach
  needs a separate state-lifetime change covering nested callbacks, modal owners,
  unpublished windows and final sidecar reclamation. The existing lease regression
  cases remain the current contract; COM ownership cleanup does not replace it.
- **System popup discovery/subclassing: retain current appearance.** The code
  customizes native popup cascade markers using bounded same-thread discovery,
  exact subclass identity/generation checks and resource-specific cleanup. Removing
  it would change visible behavior. Its current appearance benefit is retained;
  any simplification needs a separate maintainer decision, not an unsafe cleanup.
- **TaskDialog dynamic loading: retain the no-direct-import contract.** System32
  loading observes the activation context and holds the module through every call.
  The checked union conversion relies on the exact exported ABI; transmute does
  not improve that proof. Direct import or a loading dependency requires a separate
  compatibility-policy change.
- **Windows text and message operations: retain native semantics.** Windows
  comparison/code-page behavior, exact UTF-16 handling and native messages and
  callbacks have no established behavior-equivalent safe replacement here.
  One-line wrappers hiding unsafe tokens would leave their obligations unchanged.

OLE drop targets use the pinned `windows` bindings' `IDropTarget` implementation
and typed `IDataObject` calls. The generated COM implementation owns interface
layout, QueryInterface and reference counting; this delegation does not prove the
remaining native crossings safe. Each registration retains an owned interface
until its exact HWND is revoked, including partial list/overlay registration.
Every callback holds a local strong reference before provider calls or UI
dispatch, so reentrant revocation cannot reclaim its implementation mid-call.
Provider callback arguments remain borrowed, and no application-state lease may
survive a provider call. `#[implement(IDropTarget, Agile = false)]` disables the
macro's default IAgileObject and free-threaded marshaler support. The target
remains confined to its OLE UI apartment; generated interface support must not
authorize cross-thread UI state access.
Unlike the former two-interface implementation, the pinned macro also exposes
its IInspectable metadata identity and library-specific borrowed dynamic-cast
convention. These are accepted binding-provided introspection, not new
application operations or marshaling authorization; the app never uses the
dynamic-cast pseudo-interface. The interface regression test checks canonical
IUnknown identity and rejects IDataObject, IAgileObject and IMarshal queries.
Successful GetData output immediately enters a non-Copy medium owner, which
checks the TYMED discriminant before union access and calls ReleaseStgMedium
exactly once. Typed COM does not replace that medium contract, bounded UTF-16
extraction, or state/authorization revalidation after provider-controlled work.

The secure text-save and recovery-export-folder event sinks also use
`#[implement(IFileDialogEvents, Agile = false)]`. Their owner HWND and
`Rc<RefCell<_>>` selection state belong to the initialized UI apartment. The
dialog registration and local owned interface keep each sink alive through
modal dispatch; the registration is removed before normal local release.
Callback interface parameters stay borrowed. Disabling automatic IAgileObject
and IMarshal support removes the unsupported free-threaded contract; it does
not forbid every correctly marshaled COM use. It grants no permission to move
raw interfaces or access UI selection state across threads.

`WinRtGuard` is created only after successful `RoInitialize` and carries a
private `PhantomData<Rc<()>>` marker, preventing safe transfer or sharing across
threads. Its resource-specific destructor balances initialization on the UI
apartment after the WinRT queries finish. The existing module-private OLE guard
remains local to its initialization and UI run scope; broader guard redesign is
deferred because no wrong-thread use was identified in those call sites.

The native UI exceptions exist where Win32 handle, message, drawing, theme, and
subclass APIs cannot be expressed through the safe bindings. Those call sites
must validate window and object ownership, use owned snapshots instead of live
state references, release application state leases before reentrant Windows
dispatch, and restore borrowed drawing state and locally owned GDI resources.
Subclass state remains alive until confirmed detach or window destruction; an
ambiguous removal leaks the bounded context instead of risking dangling native
refdata. These presentation exceptions do not grant rename or journal authority.

`windows/icon_worker.rs` is the reviewed Shell-icon boundary. Its single tracked
worker initializes and balances COM on that same STA, pumps its own message
queue between Shell calls, and never receives `AppState`, HWND, model pointers,
or file-mutation authority. `SHGetFileInfoW` reads only owned, terminated and
MAX_PATH-bounded representative text; the returned process-shared system image
list is validated read-only and carried as a scalar borrowed identity, never
destroyed or written. The UI alone attaches that list and applies checked icon
indices to current rows. A short wake gate serializes pointer-free posts against
terminal thread-ID retirement, while its request mutex is never held across a
Shell call. `WM_DESTROY` can revoke requests through a disjoint callback sidecar
without borrowing an already leased `AppState`; the run-scope reclaim hold keeps
the runtime lock alive until the sole JoinHandle is observed finished and joined.
The UI keeps pumping during a blocked provider call; no hard Shell timeout is
claimed.

The ignored refresh-stage diagnostic keeps its original detached ListView
fixture. Its versioned asynchronous-icon JSON measures UI text, issue and
native-row staging only; it has no icon worker and cannot establish Shell
latency, icon settlement, or production responsiveness. Those require the
tracked-worker native cases and source-bound product observations.

The ignored icon-delay diagnostic in `windows/list_view.rs` installs a subclass
only on its test-owned HWND. Its boxed context remains on the owning UI thread
through synchronous destruction; `WM_NCDESTROY` removes the exact subclass and
records retirement. A guard handles fallible probe-thread creation and retains
the context on uncertain native cleanup. The independent thread receives only
a copied HWND and performs a bounded `WM_NULL` probe; it finishes before the
owner destroys the window. Callback failures are contained before crossing the
native ABI. This historical test injects a fixed delay into its test-only cache
lookup seam, without installing a provider. Its timings are
test-build diagnostics, separate from production executable measurements.

Button and decorative separator painting uses pure bounded rectangles. Interactive
outlines and decorative hairlines stay one physical pixel; focus/pressed insets
use the live control DPI without changing control layout or command metadata.
Adjacent buttons in a catalog group share one boundary owned by the preceding
button. Separate control/divider brushes are constructed in the existing owned
appearance resource set and remain alive through synchronous drawing; partial
allocation failure drops the candidate set and retains the previous resources.
Button drawing saves the borrowed DC, clips pressed text to its original item
bounds, and restores DC attributes on every return. A failed DC save/clip
request delegates drawing without modifying caller state. Decorative separator
slots are cleared with their owning surface brush before the centered line, avoiding stale pixels across theme changes. These changes do
not retain callback pointers or introduce new state leases or mutation authority.

The dark FileList uses the existing per-control theme association and a bounded
postpaint fill below the last native row. It queries only its validated ListView,
checks the native count against the leased model, and consumes synchronous local
rectangle storage. Failed queries skip custom fill. Pure bounds exclude header,
occupied/selected rows and non-client scrollbar chrome; no native input or
selection rendering is replaced. System/Forced Colors skip this custom path
and restore the default association. Theme failure retains the existing native
fallback, with no process-wide hooks, private API ordinals or new production
subclasses. The native blank-body regression routes real ListView custom-draw
notifications through a test-owned parent subclass. Its boxed UI-thread context
and brush remain live through confirmed parent destruction; failed destruction
retains that bounded context instead of leaving dangling callback refdata.

Appearance group boxes use a local UI-thread `Rc` ownership protocol. The parent
owns each group state, and subclass refdata owns one separate strong share.
Each callback acquires an active strong share before dispatch. Short `RefCell`
borrows copy strong palette/font owners before `BeginPaint` or `WM_GETFONT`;
no interior borrow survives a native call. Those owners retain the GDI resources
through nested style refresh or destruction, rather than copying raw handles.
Child `WM_NCDESTROY` marks its exact state retired once and clears its resource
shares. Paint rechecks that retirement after reentrant dispatch and skips further
drawing with a destroyed child or its paint DC. Each `BeginPaint` is paired
with `EndPaint` using its original HWND and PAINTSTRUCT; a nested destruction
does not establish that the HWND remains valid or that native cleanup succeeds.
No subsequent drawing depends on that cleanup. Parent style updates skip
retired state through their owned share and never dereference an independently
freed child allocation. The teardown attempts to remove the exact subclass
before forwarding final destruction and releases its publication share only
after confirmed removal. If removal is uncertain, at most one inert refdata
share per child is retained; its cleared
palette/font shares cannot retain the dialog's drawing resources. Installation
failure releases the unregistered share, while partial parent creation retains
registered shares until child teardown. The global callback protocol and popup
ownership remain unchanged.

Modal input/details prompts keep one caller-owned `CallbackState<PromptState>`
allocation until all synchronous callbacks return. Each state-reading callback
must acquire its exclusive lease; nested color/draw callbacks use native fallback
while it is busy. Font, layout, and appearance refreshes release that lease before
an immediate palette repaint, focus assignment, clipboard work, or destruction.
`WM_NCDESTROY` clears publication without touching a possibly leased value. The
modal loop checks completion and exact publication before waiting for each
message, so it recognizes destruction that did not set the completion flag. The modal owner destroys
any still-published window before dropping state/fonts on every return path.

Editable prompts seed their controls with the original bounded UTF-16 units,
including unpaired surrogates. Accepting an unchanged value therefore preserves
the exact command input instead of feeding lossy display text back into it.

`normalized_final_leaf` keeps the source handle live for the synchronous
`GetFinalPathNameByHandleW` call, passes either a null zero-length output or the
exact checked writable slice, bounds each allocation by
`MAX_NORMALIZED_FINAL_PATH_UTF16_UNITS`, and retries a changed required size
once. It retains only a final component bounded by
`MAX_WINDOWS_LEAF_NAME_UTF16_UNITS`. Native API failures remain typed planning
blockers.

Process-token queries adopt only the real handle returned by a successful
OpenProcessToken into `OwnedHandle`, exactly once. The process pseudo-handle
stays borrowed. Native queries borrow the owner's raw handle until return;
standard ownership replaces the custom CloseHandle guard without changing the
elevation policy. GDI, library, menu and global-memory resources retain their
resource-specific destructors and must not be adopted as `OwnedHandle`.

Prepared clipboard memory has a non-Copy HGLOBAL owner recording its byte
capacity. UTF-16 population checks that capacity and completes allocation,
locking, copying and unlocking before OpenClipboard or EmptyClipboard. Preparation,
session-opening, emptying and publication failures leave the block locally owned
and its destructor centralizes GlobalFree. Only successful SetClipboardData
relinquishes ownership; a later CloseClipboard failure does not reclaim the
system-owned block. Failure after EmptyClipboard cannot restore the prior
clipboard contents. Native allocation/clipboard calls remain necessary for the
movable-memory transfer contract; exact UTF-16 units, including surrogates, are
preserved independently of display text.

Native rename and single-entry directory query buffers use explicit `repr(C)`
records with complete bounded UTF-16 array fields. Compile-time checks compare
their field offsets and alignment with the pinned SDK records and prove backing
capacity for the exact bytes passed to the OS. Appending storage after an SDK
one-element array would still require raw pointer arithmetic and would not make
an extended slice of that Rust field valid. Rename copies into its real array
after rejecting empty, NUL-containing or over-limit leaves; no-replacement flags
and the retained source/parent handles remain unchanged. Directory output is
initialized on every call, validates returned bytes and complete bounded name
lengths, and rejects a next-entry offset in single-entry mode before slicing.
Unpaired surrogates remain exact UTF-16 units. NtSetInformationFile and
NtQueryDirectoryFile are retained because path-based alternatives do not preserve
identity-bound no-replacement operations and retained-directory enumeration.
Each synchronous call borrows live handles and an aligned, sufficiently large
record only until return; cancellation and aggregate admission budgets still
apply independently of buffer representation.

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
candidate-bound Windows VM observations under a selected
[`config/vm-automated-v1.json`](config/vm-automated-v1.json) or
[`config/vm-automated-v2.json`](config/vm-automated-v2.json) profile. Local and
hosted validation entrypoints default to v2; historical v1 evidence requires an
explicit v1 selection. The v1
strict contract and its historical failures retain their original meaning. V2
is the separate owned-resources contract described below. Human input
and visual review are not required pass conditions and cannot substitute for
missing automated evidence. This changes the release evidence contract; the
filesystem, identity, no-replacement, journal and recovery invariants above
remain mandatory.

Both profiles are frozen before a campaign. Each declares 22 target verdicts: two
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

### Strict v1 runner environment

Preserving a failed execution and cleaning its owned resources are separate
operations. A collected failed UI or recovery result may authorize owned-root
cleanup only after its complete output inventory has been copied outside the
guest roots and checked against the retained byte counts, hashes and bound
result. The observer must be terminal, its process jobs closed, and any changed
desktop settings verifiably restored. Missing or partial output, uncertain
restoration and unresolved owned lifetimes retain the roots. Cleanup permission
does not change the original result, permit another workload, or establish a
passing campaign. The strict runner-environment predicate below still applies.

Product behavior, owned-resource cleanup and the external runner environment
must remain distinguishable in retained evidence. Unknown ownership, incomplete
observations or uncertain restoration cannot establish successful cleanup.
An observed external process difference is not by itself proof of a product
resource leak, but it still fails the strict environment contract. A separate
owned-cleanup proof cannot replace the original execution or environment
receipt. Cleanup after a strict environment rejection requires externally
preserved, integrity-checked failure evidence before any owned-root removal;
it cannot authorize the next campaign slot or reclassify a prior failure.

The completed bounded RuntimeBroker diagnostic does not justify a new process
allowance. Missing preparation-control coverage, failed diagnostic attempts,
best-effort event delivery and unidentified historical lifetimes remain limits
on its conclusions. No change in those conclusions is inferred from a later
successful owned cleanup.

Post-failure owned-root deletion must stay bound to the original root and base
file identities and their retained security descriptors. Native cleanup reads
ownership and ACLs from the held root handle, enumerates through held directory
handles, and opens only single child components relative to those handles.
The enumerated child identity must match the opened object before disposition.
Raw UTF-16 name units must survive enumeration unchanged. Reparse traversal,
root or child replacement, unknown ownership and incomplete observations refuse
cleanup; pathname checks and sharing flags alone are insufficient. These
cleanup capabilities grant deletion only for the verified disposable run tree;
they neither enable privileges nor authorize terminating external OS processes.

Controller cleanup requires complete process and scheduled-task inventories to
show no runner delta after intervention and after resource removal. One initial
same-user, same-session process delta may be waited for only when it is one of:

- The exact `System32\smartscreen.exe -Embedding` broker.
- The exact DesktopSpotlight server invocation of
  `System32\backgroundTaskHost.exe`, authenticated as the
  `MicrosoftWindows.Client.CBS` package's `Global.DesktopSpotlight` application.

Both classes require valid Microsoft Authenticode signatures, canonical system
paths, frozen process lifetimes and command-line arguments, and a SYSTEM
`System32\svchost.exe` parent hosting the running `DcomLaunch` service. This does
not assert that `DcomLaunch` is the parent's only hosted service. The limit is one
initial process across both classes.

DesktopSpotlight also requires the process's native package full name and
application user model ID from the same held handle as its PID, creation time,
image, token owner and session. The controller captures this identity before
slower owner inventory calls. Observations and capture failures persist across
inventory retries; a process disappearing after an incomplete capture cannot
turn cleanup into a zero-delta success. Native creation times retain all 100 ns
FILETIME ticks; matching the CIM inventory normalizes only its microsecond
precision. Process access permits identity queries and waiting, token access
permits queries, and neither boundary grants termination rights or enables a
privilege.

A bounded, explicitly owned Windows PowerShell registration query completes
before the runner baselines. Its child must exit, close its job and streams, and
leave no owned lifetime. Missing CBS registration disables only the
DesktopSpotlight class. The result crosses remoting as one bounded JSON string,
including JSON null for a missing package, so transport annotations cannot enter
the registration record. Independent verification still rejects unexpected data
fields. Classification rechecks that exact registration through
the current user's native package APIs without starting another process. The
package must match the fixed Microsoft identity, system signature status, and
nondevelopment registration. Its protected SystemApps manifest must independently
bind the package identity, DesktopSpotlight application, background tasks and
app service. The manifest read is bounded and hash-bound; its exact ordinary
path and ancestors must have trusted owners and no effective untrusted rights
that can alter or replace the protected objects. The drive root may permit
creation of unrelated directories. This class requires the Windows directory
to be directly below its drive root, so the fixed path inventory includes every
ancestor. The verifier checks the retained bytes and typed access-control entries
independently.

The controller applies a six-minute monotonic deadline to complete process and
scheduled-task polling. DesktopSpotlight additionally requires a signaled exit,
creation and exit times, and an exit code from its original held handle, followed
by successful handle closure. The exit code records an observation; it does not
establish successful OS work or a cause of exit. Both classes require complete
zero-delta inventories before the deadline and after resource removal. A late
poll fails cleanup. A stalled inventory call may delay controller return, but
cannot produce a passing late result. Any identity mismatch, second process,
task delta, incomplete inventory, or timeout fails cleanup. The controller never
terminates either OS process.

The separate [RuntimeBroker identity diagnostic](DEVELOPMENT.md#runtimebroker-identity-diagnostics)
does not participate in this acceptance predicate. It retains target and parent
handles with `PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE` and token handles
with `TOKEN_QUERY`, without enabling privileges or assigning observed OS
processes to a job. Its owned job contains only the collector and its compiler
children. PID and native creation FILETIME bind a lifetime; start/stop events
and current parent PID lookups are auxiliary observations. Event loss or query
failure stays explicit and cannot justify allowing an additional process.

### Owned-resources v2 runner environment

The v2 profile has schema `darkrenamer-vm-automated-profile-v2`, ID
`vm-automated-v2-owned-resources` and revision 2. Its canonical statement uses
`darkrenamer-vm-automated-statement-v2` and keeps the exact profile ID, revision
and SHA-256 source blob binding. V1 keeps its v1 schema and strict predicate.
Neither a v1 failed record nor its separately verified cleanup proof can be
promoted into v2 acceptance. The 30 first-attempt slots, 22 product targets,
five gates, candidate bytes, source binding and authenticated hosted attestation
are unchanged.

V2 retains complete raw OS process and task observations. A new, surviving, or
multiple ambient OS processes do not by themselves fail the v2 environment
predicate when owned lifetimes, jobs, roots and protected resources are fully
accounted for and essential input, focus and settings remain intact. This is
not a claim that a process is harmless because of its name, signature, parent
or absence from an owned Job. Directly launched helpers and protected-resource
connections must be accounted for; uncertain ownership, missing lifetimes or
incomplete inventories fail closed. Unexpected scheduled-task creation,
deletion or definition changes still fail.

Owned process or Job survivors, unresolved owned tasks/files/roots, failed
journal or product checks, input/focus interference, setting restoration
failure, missing or inconsistent evidence and incomplete owned-root cleanup
remain blockers. Failure cleanup preserves the original result and cannot
authorize a later slot. V2 verifies observed file safety, product behavior,
required environment and explicit owned-resource cleanup. It does not
guarantee whole-session OS process stasis, complete causality of ambient OS
activity, all broker-mediated escape paths or remote VM hardware attestation.
The trusted VM producer and private raw-evidence boundary remain in force.

### Common evidence and promotion bindings

The independent verifier derives all 22 target verdicts from raw observations;
producer summaries, `passed` flags, and legacy `review_required` values are not
verdict inputs. The five required gate records bind separate properties:

Evidence PNG dimensions are checked against the bound observation immediately
after IHDR parsing and before any IDAT inflation. One verifier reader also
accounts decoded pixels across the complete campaign, with a 144 Mi-pixel total
limit sized for the frozen layout profile and one maximum-size recovery image;
repeated layout captures therefore cannot each consume the full
per-image decoder allowance.

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
[`DISTRIBUTION.md`](DISTRIBUTION.md#immutable-release-promotion). An attestation
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

The file ListView's existing UI-thread notification subclass also paints dark
nonclient scrollbar chrome after forwarding native processing exactly once.
`GetScrollBarInfo` supplies the live native rectangle, arrow length, thumb and
component states. Pure splitting rejects invalid or out-of-range geometry; a
saved window DC excludes the entire client rectangle before bounded fills.
The control continues to own ranges, hit-testing, dragging, wheel/keyboard input
and accessibility. Only copied palette values cross the state lease boundary,
with no lease retained across native scroll tracking. Failed state/DC/geometry
queries leave native drawing intact. Native/Forced Colors resolution bypasses
custom chrome. Stock GDI selections and clipping are restored, and every
successfully acquired window DC is released on the UI thread.

Command rail hover tracking uses a control-local UI-thread subclass with scalar
reference data and the documented `TrackMouseEvent(TME_LEAVE)` contract. It
retains no application-state or heap pointer across native processing. Native
button input and accessibility continue through `DefSubclassProc` exactly once;
signed client coordinates and a live stack `GetClientRect` query clear hot state
on captured movement outside the control. Leave, capture loss/cancel, hide,
disable, and destruction clear hot state, and `WM_NCDESTROY`
removes the exact subclass before forwarding. Failed tracking/state updates
retain native input processing; partial rail construction destroys its owned
children. This callback justifies the explicit reviewed extern
function inventory entry for `command_rail.rs`; it does not authorize other
unsafe boundaries. Standard prompt custom drawing reads the live native
`BS_DEFPUSHBUTTON` style on the callback's bound BUTTON to retain its default
cue when common-control custom-draw flags omit `CDIS_DEFAULT`.
